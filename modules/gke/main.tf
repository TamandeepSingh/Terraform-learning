# ============================================================
# modules/gke/main.tf — GKE Standard cluster + node pool
# ============================================================
#
# Architecture overview
# ─────────────────────
#  ┌──────────────────────────────────────────────────┐
#  │  VPC (from vpc module)                           │
#  │  ┌─────────────────────────────────────────────┐ │
#  │  │  Subnet  10.10.0.0/24  (nodes get IPs here) │ │
#  │  │  ├─ secondary range: gke-pods    10.20.0.0/16│ │
#  │  │  └─ secondary range: gke-services 10.30.0.0/20│ │
#  │  └─────────────────────────────────────────────┘ │
#  │                                                  │
#  │  GKE Cluster (regional — control plane in 3 zones)│
#  │  └─ Node Pool  (worker VMs in each zone)         │
#  └──────────────────────────────────────────────────┘
#
# Key concepts used:
#   VPC-native      — pods get IPs from the subnet's secondary ranges
#                     (required for private clusters and better peering support).
#   Private cluster — worker nodes have no public IP; they reach Google APIs
#                     via private_ip_google_access on the subnet.
#   Workload Identity — pods can act as GCP service accounts without key files.
#   Regional cluster — control plane replicated across 3 zones = high availability.

# ---------------------------------------------------------------
# GKE Cluster
# ---------------------------------------------------------------
resource "google_container_cluster" "primary" {
  name     = var.cluster_name

  # "location" controls cluster topology:
  #   region (e.g. us-central1)  → regional cluster: 3 control-plane replicas,
  #                                 nodes spread across 3 zones. HA, slightly pricier.
  #   zone   (e.g. us-central1-a) → zonal cluster: 1 control plane. Cheaper, no HA.
  # Use region for production workloads.
  location = var.region

  # Pin the zones where worker nodes run. This makes zones known at plan time,
  # which lets the load_balancer module use zone names as static for_each keys.
  node_locations = var.node_zones

  # Attach the cluster to our VPC and subnet.
  # GKE accepts both the short name and the self-link URL here.
  network    = var.vpc_name
  subnetwork = var.subnet_name

  # -------------------------------------------------------
  # VPC-native networking (Alias IPs)
  # -------------------------------------------------------
  # Without ip_allocation_policy GKE uses legacy routes-based networking.
  # VPC-native is required for:
  #   • Private clusters (nodes without public IPs)
  #   • Better VPC peering (pod IPs are routable inside the VPC)
  #   • Workload Identity
  #
  # cluster_secondary_range_name  → where pod IPs come from
  # services_secondary_range_name → where ClusterIP IPs come from
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # -------------------------------------------------------
  # Private cluster configuration
  # -------------------------------------------------------
  # enable_private_nodes = true:
  #   Worker nodes get only internal IPs. Traffic to Google APIs goes
  #   through private_ip_google_access; internet egress requires Cloud NAT.
  #
  # enable_private_endpoint = false:
  #   The Kubernetes API server (kubectl) is still reachable from the internet
  #   via its public endpoint. Set to true in production and access via VPN/bastion.
  #
  # master_ipv4_cidr_block:
  #   A /28 CIDR reserved for the control plane's peered VPC. GKE peers its
  #   managed VPC into yours so the nodes and masters can talk on private IPs.
  #   This range must not overlap with your subnet or any other CIDRs.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

  # -------------------------------------------------------
  # Remove and replace the default node pool
  # -------------------------------------------------------
  # GKE always requires at least one node pool to bootstrap the cluster.
  # We tell it to delete that default pool right after creation so we can
  # create our own pool (below) with precise configuration.
  # initial_node_count is still required even though the pool is deleted.
  remove_default_node_pool = true
  initial_node_count       = 1

  # node_config here applies ONLY to the temporary bootstrap node GKE
  # creates in the default pool before deleting it.
  # Without this block GKE defaults to pd-balanced (SSD), which counts
  # against the SSD_TOTAL_GB quota (250 GB default) and can cause quota
  # errors before the node is even deleted.
  # pd-standard uses HDD quota (2 TB default) — safe for a throwaway node.
  # disk_size_gb = 10 is the minimum GKE allows.
  node_config {
    disk_type    = "pd-standard"
    disk_size_gb = 20
  }

  # -------------------------------------------------------
  # Workload Identity
  # -------------------------------------------------------
  # Workload Identity is the recommended way to grant pods access to GCP APIs.
  # Instead of mounting service-account JSON keys (which is a security risk),
  # a Kubernetes SA is federated to a GCP SA via annotation.
  #
  # workload_pool format: "<project-id>.svc.id.goog"
  # After enabling, annotate a K8s SA:
  #   kubectl annotate serviceaccount <ksa> \
  #     iam.gke.io/gcp-service-account=<gsa>@<project>.iam.gserviceaccount.com
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # -------------------------------------------------------
  # Cloud Operations (Logging & Monitoring)
  # -------------------------------------------------------
  # Sends container logs and metrics to Cloud Logging / Cloud Monitoring.
  # GKE-specific system component logs are included automatically.
  logging_service    = "logging.googleapis.com/kubernetes"
  monitoring_service = "monitoring.googleapis.com/kubernetes"

  # -------------------------------------------------------
  # Maintenance window
  # -------------------------------------------------------
  # GKE auto-upgrades control planes and nodes (security patches, new k8s versions).
  # This window tells GKE *when* it is allowed to perform maintenance.
  # Saturday and Sunday 03:00–11:00 UTC (8h each day).
  #
  # Why 8h instead of 4h?
  # GKE requires >= 48h of maintenance availability in any 32-day window.
  # 4h × 2 days × 4 weekends = 32h → rejected (< 48h).
  # 8h × 2 days × 4 weekends = 64h → accepted (>= 48h).
  maintenance_policy {
    recurring_window {
      start_time = "2024-01-01T03:00:00Z"
      end_time   = "2024-01-01T11:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }
  }

  # Prevents accidental cluster deletion via `terraform destroy`.
  # Set to true in production — you'd need to change this to false first.
  deletion_protection = false
}

# ---------------------------------------------------------------
# Node Pool
# ---------------------------------------------------------------
# A node pool is a group of identically configured VMs that run workloads.
# You can have multiple pools with different machine types — e.g. a general
# CPU pool and a high-memory pool for ML inference.
resource "google_container_node_pool" "primary_nodes" {
  name     = "${var.cluster_name}-node-pool"
  cluster  = google_container_cluster.primary.id

  # Must match the cluster's location (region or zone).
  # For a regional cluster this means nodes are spread across all 3 zones.
  location = var.region

  # initial_node_count is *per zone*. In a regional cluster (3 zones) the
  # actual starting count is initial_node_count × 3.
  initial_node_count = var.initial_node_count

  # -------------------------------------------------------
  # Cluster Autoscaler
  # -------------------------------------------------------
  # GKE's cluster autoscaler watches for Pending pods and scales node count
  # up (when pods can't be scheduled) or down (when nodes are underutilised).
  # min / max are also per zone.
  autoscaling {
    min_node_count = var.min_node_count
    max_node_count = var.max_node_count
  }

  # -------------------------------------------------------
  # Node management
  # -------------------------------------------------------
  management {
    auto_repair  = true # GKE replaces nodes that fail health checks
    auto_upgrade = true # GKE upgrades node version alongside the control plane
  }

  # -------------------------------------------------------
  # Node configuration
  # -------------------------------------------------------
  node_config {
    machine_type = var.machine_type # e2-medium = 2 vCPU, 4 GB — good for dev

    # Use the minimal SA created by the iam module instead of the
    # default Compute SA (which has broad Editor access).
    service_account = var.node_service_account

    # "cloud-platform" is the broadest OAuth scope, but actual API access
    # is controlled by the SA's IAM roles — using this scope + minimal IAM
    # roles is the recommended pattern (simpler than narrowing scopes).
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    # pd-standard uses HDD — fine for dev/learning where disk I/O is not critical.
    # Disk type comparison:
    #   pd-standard  → HDD, quota: DISKS_TOTAL_GB (default 2 TB)  ← dev choice
    #   pd-balanced  → SSD, quota: SSD_TOTAL_GB   (default 250 GB) ← easily exhausted
    #   pd-ssd       → SSD, quota: SSD_TOTAL_GB   (default 250 GB)
    # Switch to pd-balanced or pd-ssd in production when throughput matters.
    # Regional cluster: 3 zones × initial_node_count nodes × disk_size_gb
    # must stay within the chosen quota (e.g. 3 × 1 × 50 GB = 150 GB SSD).
    disk_type    = "pd-standard"
    disk_size_gb = var.disk_size_gb

    # GKE_METADATA mode activates Workload Identity on the node.
    # The node's metadata server intercepts requests for credentials and
    # returns tokens scoped to the pod's annotated GCP SA instead of the
    # node SA. Pods cannot access the raw node SA credentials.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # Shielded nodes protect against boot-level rootkits and malware.
    #   secure_boot          — verifies the boot chain hasn't been tampered with.
    #   integrity_monitoring — measures the boot sequence and alerts on changes.
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    # This tag matches the firewall rule in the vpc module that opens
    # ports 443 and 10250 for control-plane → node communication.
    tags = ["gke-node"]

    labels = {
      environment = var.environment
      managed_by  = "terraform"
    }
  }

  # The cluster autoscaler changes initial_node_count externally.
  # Ignoring it prevents Terraform from trying to "fix" autoscaler-driven changes.
  lifecycle {
    ignore_changes = [initial_node_count]
  }
}
