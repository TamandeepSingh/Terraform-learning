# ============================================================
# modules/vpc/main.tf — VPC, subnet, and firewall rules
# ============================================================
# This module creates the networking foundation used by every
# other module (GCE, GKE). It outputs IDs and names that other
# modules reference to attach their resources to the network.

# ---------------------------------------------------------------
# VPC Network
# ---------------------------------------------------------------
# google_compute_network creates a VPC — a global, software-defined
# network that spans all GCP regions. Subnets are regional slices of it.
#
# auto_create_subnetworks = false → "custom mode" VPC.
# GCP has two modes:
#   • auto mode  — one subnet is auto-created per region with preset CIDRs.
#   • custom mode — you define every subnet (always use this in production).
# Custom mode prevents IP collisions when peering VPCs or adding regions.
resource "google_compute_network" "vpc" {
  name                    = var.vpc_name
  auto_create_subnetworks = false
  description             = "Custom VPC managed by Terraform"
}

# ---------------------------------------------------------------
# Subnet
# ---------------------------------------------------------------
# A subnet is a regional IP range carved out of the parent VPC.
# VMs and GKE nodes placed in this subnet receive IPs from ip_cidr_range.
#
# GKE requires VPC-native networking (alias IPs). That means the subnet
# needs two *named* secondary IP ranges:
#   • One for pod IPs  — each node borrows a /24 from this pool.
#   • One for service (ClusterIP) IPs — each service gets one IP here.
#
# These ranges must not overlap with each other or ip_cidr_range.
resource "google_compute_subnetwork" "subnet" {
  name                     = var.subnet_name
  network                  = google_compute_network.vpc.id
  region                   = var.region
  ip_cidr_range            = var.subnet_cidr # primary range — nodes / VMs

  # private_ip_google_access = true lets VMs without a public IP reach
  # Google APIs (Cloud Storage, Artifact Registry, Secret Manager, etc.)
  # over Google's private network — no Cloud NAT or public IP needed.
  private_ip_google_access = true

  # ---------- Secondary IP ranges for GKE VPC-native networking ----------
  # GKE reads these range names from the cluster resource to allocate IPs.
  # The names must match what you pass in the GKE module's ip_allocation_policy.

  secondary_ip_range {
    range_name    = var.pods_range_name  # e.g. "gke-pods"
    ip_cidr_range = var.pods_cidr        # e.g. 10.20.0.0/16 → up to 65 536 pod IPs
  }

  secondary_ip_range {
    range_name    = var.services_range_name # e.g. "gke-services"
    ip_cidr_range = var.services_cidr       # e.g. 10.30.0.0/20 → up to 4 096 services
  }
}

# ---------------------------------------------------------------
# Firewall — HTTP + SSH ingress for web-server VMs
# ---------------------------------------------------------------
# GCP firewalls live at the VPC level and match packets before they
# reach the VM. Rules are applied to VMs via *network tags* — any VM
# tagged with one of target_tags receives this rule.
#
# GCP default behaviour:
#   Ingress  — all blocked unless a rule explicitly allows it.
#   Egress   — all allowed unless a rule explicitly blocks it.
resource "google_compute_firewall" "allow_http_ssh" {
  name      = var.firewall_name
  network   = google_compute_network.vpc.id
  direction = "INGRESS"
  priority  = 1000 # lower number = higher priority; default is 1000

  # allow blocks define permitted protocol + port combinations.
  allow {
    protocol = "tcp"
    ports    = ["80"] # HTTP — web server traffic
  }

  allow {
    protocol = "tcp"
    ports    = ["22"] # SSH — admin access to VMs
  }

  # concat merges the two lists so HTTP is open to the world while
  # SSH is only reachable from your specified CIDR ranges.
  source_ranges = concat(["0.0.0.0/0"], var.allowed_ssh_ranges)

  # Only VMs that carry one of these tags receive this rule.
  target_tags = var.target_tags

  description = "Allow HTTP (80) from anywhere and SSH (22) from allowed ranges"
}

# ---------------------------------------------------------------
# Firewall — GKE control plane → node communication
# ---------------------------------------------------------------
# The GKE control plane (Google-managed master nodes) needs to reach
# worker nodes to:
#   • Pull pod status from the kubelet (port 10250)
#   • Serve webhook admission controllers (port 443)
# Without this rule, GKE health checks and webhook calls would fail.
resource "google_compute_firewall" "allow_gke_control_plane" {
  name      = "${var.vpc_name}-allow-gke-cp"
  network   = google_compute_network.vpc.id
  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["443", "10250"]
  }

  # 0.0.0.0/0 is acceptable here for a learning setup because GKE nodes
  # are tagged and the ports are specific. Tighten to the master CIDR in prod.
  source_ranges = ["0.0.0.0/0"]

  # Only nodes tagged "gke-node" (set in the GKE module) receive this rule.
  target_tags = ["gke-node"]

  description = "Allow GKE control plane to reach node kubelets and webhooks"
}
