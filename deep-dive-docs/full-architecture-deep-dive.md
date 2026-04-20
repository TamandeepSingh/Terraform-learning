# Full Architecture Deep Dive
# Calculator App on GKE — Every Resource Explained

This document covers every single resource in both repositories — what it is, why it exists,
how it is configured, and exactly how data flows through it. The final section traces a
single HTTP request all the way from a user's browser to the Flask pod and back.

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Terraform Module Map](#2-terraform-module-map)
3. [VPC & Networking Foundation](#3-vpc--networking-foundation)
4. [Firewall Rules](#4-firewall-rules)
5. [GKE Cluster](#5-gke-cluster)
6. [GKE Node Pool](#6-gke-node-pool)
7. [IAM — Node Service Account](#7-iam--node-service-account)
8. [CI/CD IAM — Artifact Registry + Workload Identity](#8-cicd-iam--artifact-registry--workload-identity)
9. [GCP Load Balancer — All 7 Resources](#9-gcp-load-balancer--all-7-resources)
10. [Kubernetes Resources](#10-kubernetes-resources)
11. [The Flask Application](#11-the-flask-application)
12. [CI/CD Pipeline](#12-cicd-pipeline)
13. [Complete Network Path: User → Pod → User](#13-complete-network-path-user--pod--user)
14. [Internal Cluster Networking](#14-internal-cluster-networking)
15. [IAM & Security Architecture](#15-iam--security-architecture)

---

## 1. System Overview

```
                              ┌─────────────────────────────────────────────────────────────────┐
                              │  GitHub                                                          │
                              │  ┌──────────────────────────────┐                               │
                              │  │  gke-sample-app repo         │                               │
                              │  │  app/   k8s/   Dockerfile    │                               │
                              │  │  .github/workflows/ci-cd.yml │                               │
                              │  └──────────────┬───────────────┘                               │
                              │                 │ git push → main                               │
                              │  ┌──────────────▼───────────────┐                               │
                              │  │  GitHub Actions Runner        │                               │
                              │  │  Job 1: pytest               │                               │
                              │  │  Job 2: docker build + push  │──── OIDC token ──►  GCP STS  │
                              │  │  Job 3: kubectl set image     │◄─── SA access token ─────────┘
                              └──────────────────────────────────┘
                                               │
                              ┌────────────────▼────────────────────────────────────────────────┐
                              │  GCP Project                                                     │
                              │                                                                  │
                              │  Artifact Registry                                               │
                              │  us-central1-docker.pkg.dev/PROJECT/calculator-repo/calculator  │
                              │                       ▲                 │                        │
                              │             docker push│                │ image pull (private IP)│
                              │                        │                ▼                        │
                              │  ┌─────────────────────────────────────────────────────────┐    │
                              │  │  GKE Cluster  (us-central1, regional, 3 zones)          │    │
                              │  │                                                         │    │
                              │  │  ┌───────────┐  ┌───────────┐  ┌───────────┐           │    │
                              │  │  │ Node  a   │  │ Node  b   │  │ Node  c   │           │    │
                              │  │  │10.10.0.x  │  │10.10.0.y  │  │10.10.0.z  │           │    │
                              │  │  │           │  │           │  │           │           │    │
                              │  │  │ Pod       │  │ Pod       │  │           │           │    │
                              │  │  │10.20.0.x  │  │10.20.0.y  │  │           │           │    │
                              │  │  └─────▲─────┘  └─────▲─────┘  └─────▲─────┘           │    │
                              │  │        │ NodePort:30080 │              │                │    │
                              │  └────────┼───────────────┼──────────────┼────────────────┘    │
                              │           │               │              │                      │
                              │  ┌────────▼───────────────▼──────────────▼────────────────┐    │
                              │  │  GCP Global HTTP Load Balancer                         │    │
                              │  │  Forwarding Rule → HTTP Proxy → URL Map →              │    │
                              │  │  Backend Service → Instance Groups (one per zone)      │    │
                              │  │  Static IP: 34.x.x.x  (anycast)                       │    │
                              │  └────────────────────────┬───────────────────────────────┘    │
                              └───────────────────────────┼────────────────────────────────────┘
                                                          │
                                                     Internet
                                                          │
                                                   Browser / curl
```

---

## 2. Terraform Module Map

The Terraform project in `Terraform-learning/` is split into reusable modules.
Each module owns one concern. The `environments/dev/main.tf` wires them together.

```
environments/dev/main.tf
  │
  ├── module.iam           (modules/iam/)         — GKE node service account
  ├── module.cicd_iam      (modules/cicd_iam/)    — AR repo + GitHub WIF
  ├── module.vpc           (modules/vpc/)         — VPC, subnet, firewalls
  ├── module.gce           (modules/gce/)         — web-server VM (optional)
  ├── module.gke           (modules/gke/)         — GKE cluster + node pool
  ├── module.load_balancer (modules/load_balancer/) — GCP HTTP LB
  └── module.logging       (modules/logging/)     — log sink to GCS
```

**Dependency graph (Terraform resolves this automatically):**

```
module.iam    ──────────────────────────────────────────► module.gke
module.vpc    ──── vpc/subnet/range names ──────────────► module.gke
module.vpc    ──── vpc_id/subnet_id ────────────────────► module.gce
module.gke    ──── instance_group_url_map ──────────────► module.load_balancer
module.vpc    ──── vpc_name ────────────────────────────► module.load_balancer
module.cicd_iam  (no dependencies on other modules)
module.logging   (no dependencies on other modules)
```

So the apply order is:
1. `module.iam`, `module.vpc`, `module.cicd_iam`, `module.logging` — run in parallel
2. `module.gce`, `module.gke` — run after vpc (gke also waits for iam)
3. `module.load_balancer` — runs after gke and vpc

---

## 3. VPC & Networking Foundation

**File:** `modules/vpc/main.tf`

### 3.1 VPC Network — `google_compute_network`

```hcl
resource "google_compute_network" "vpc" {
  name                    = var.vpc_name          # "my-custom-vpc"
  auto_create_subnetworks = false
}
```

**What it is:** A VPC (Virtual Private Cloud) is a software-defined private network that lives
inside your GCP project. Think of it as your own private data center network — you control
all the IP address spaces, routing, and firewall rules.

**`auto_create_subnetworks = false` — Custom mode:**
GCP offers two VPC modes:
- **Auto mode**: GCP automatically creates one subnet in every region (us-central1, europe-west1, etc.)
  with pre-set CIDR ranges. You get subnets immediately but you can't control what IP ranges they use.
- **Custom mode**: You define every subnet explicitly. This is always the right choice because:
  - Pre-set ranges can clash when you peer VPCs or connect to on-premises networks
  - You know exactly what IPs are in use — no surprises

**Scope:** VPCs are global. A single VPC spans all GCP regions. Subnets inside it are regional.

---

### 3.2 Subnet — `google_compute_subnetwork`

```hcl
resource "google_compute_subnetwork" "subnet" {
  name          = "my-subnet"
  network       = google_compute_network.vpc.id
  region        = "us-central1"
  ip_cidr_range = "10.10.0.0/24"         # primary range — 256 addresses for VMs/nodes

  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "gke-pods"
    ip_cidr_range = "10.20.0.0/16"       # 65,536 pod IPs
  }
  secondary_ip_range {
    range_name    = "gke-services"
    ip_cidr_range = "10.30.0.0/20"       # 4,096 ClusterIP addresses
  }
}
```

**What it is:** A subnet is a regional slice of the VPC with a specific IP range.
VMs, GKE nodes, and pods all get IP addresses from subnet ranges.

**Primary range `10.10.0.0/24`:**
- GKE nodes (the actual VMs) get IPs here: e.g., `10.10.0.2`, `10.10.0.3`, `10.10.0.4`
- 256 total addresses, ~250 usable (GCP reserves a few)
- This is small — fine for dev where you have 3 nodes

**`private_ip_google_access = true`:**
Normally, a VM with no public IP cannot reach the internet or Google APIs.
This flag creates a special route so that VMs with only internal IPs can still
reach Google APIs (Artifact Registry, Cloud Logging, Cloud Monitoring, etc.)
over Google's private backbone — no Cloud NAT, no public IP needed.
This is what allows GKE nodes to pull images from Artifact Registry.

**Secondary ranges — why they exist:**
GKE uses a networking model called VPC-native (also called Alias IP).
In this model:
- Each node is allocated a `/24` block from `gke-pods` (256 pod IPs per node)
- When pods are created on that node, they get IPs from that node's `/24` block
- Because pod IPs come from the subnet's secondary range (which is part of the VPC),
  pods are directly routable within the VPC — no NAT needed between pods on different nodes

Without secondary ranges you'd use "routes-based" networking, which has limits on the
number of routes and doesn't work with private clusters.

**IP plan summary:**
```
10.10.0.0/24  — nodes (primary)    256 addresses
10.20.0.0/16  — pods (secondary)   65,536 addresses  (~256 pods/node × 256 nodes)
10.30.0.0/20  — services (secondary) 4,096 addresses  (one per Kubernetes Service)
172.16.0.0/28 — control plane VPC  (GKE-managed, master nodes) 16 addresses
```
None of these ranges overlap — this is required; overlapping causes routing failures.

---

## 4. Firewall Rules

GCP's default behavior: **all inbound (ingress) traffic is blocked**, all outbound (egress) is allowed.
You must explicitly open ports. Firewall rules apply to VMs via **network tags** — a tag is just a
string label attached to a VM, and any firewall rule targeting that tag applies to that VM.

### 4.1 HTTP + SSH for web-server VM — `google_compute_firewall.allow_http_ssh`

```hcl
allow { protocol = "tcp"; ports = ["80"] }   # HTTP
allow { protocol = "tcp"; ports = ["22"] }   # SSH
source_ranges = ["0.0.0.0/0"]               # from anywhere (SSH should be tightened in prod)
target_tags   = ["http-server", "ssh-server"]
```

This rule applies to the GCE web-server VM (tagged `http-server` + `ssh-server`).
Not relevant to the GKE traffic path — only for the standalone VM.

---

### 4.2 GKE control plane → node communication — `google_compute_firewall.allow_gke_control_plane`

```hcl
allow { protocol = "tcp"; ports = ["443", "10250"] }
source_ranges = ["0.0.0.0/0"]
target_tags   = ["gke-node"]
```

**Why this rule exists:**
GKE is a managed service. Your nodes are VMs in your VPC, but the control plane
(API server, scheduler, etcd) runs in a Google-managed VPC that is peered into yours.
The control plane needs to reach your nodes for two things:

- **Port 10250 (kubelet API)**: The API server calls the kubelet on each node to get
  pod status, stream logs (`kubectl logs`), exec into pods (`kubectl exec`).
- **Port 443 (webhook admission)**: If you install admission webhooks (Kubernetes
  validation/mutation controllers), the API server calls them on the node on port 443.

Without this rule, `kubectl logs` and `kubectl exec` would silently hang, and
admission webhooks would fail, potentially blocking pod scheduling.

---

### 4.3 GCP Load Balancer health checks → nodes — `google_compute_firewall.allow_lb_health_checks`

```hcl
allow { protocol = "tcp"; ports = ["30080"] }    # the NodePort
source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
target_tags   = ["gke-node"]
priority      = 900
```

**Why these specific source IPs:**
GCP's load balancer health checkers and the LB itself (when it forwards real traffic to backends)
always originate from these two fixed ranges. These never change and are documented by Google.

**Priority 900 (vs default 1000):**
Lower number = higher priority in GCP. We give this rule priority 900 so it is evaluated before
the default-deny behavior, ensuring health checks always get through.

**What happens if this rule is missing:**
- All backends show as "unhealthy" in the GCP console
- The load balancer returns HTTP 502 for every request
- The health check probes are silently dropped by the firewall

---

## 5. GKE Cluster

**File:** `modules/gke/main.tf` — resource `google_container_cluster.primary`

The cluster resource defines the control plane configuration. It does NOT directly create nodes
(that's the node pool's job), but it does define the network, security, and operational settings.

### 5.1 Regional vs Zonal

```hcl
location = "us-central1"   # region → regional cluster
```

| Setting | Zonal cluster | Regional cluster |
|---------|---------------|-----------------|
| `location` | zone (us-central1-a) | region (us-central1) |
| Control plane replicas | 1 | 3 (one per zone) |
| HA during zone outage | No (cluster down) | Yes (other zones serve) |
| Cost | Cheaper | Slightly more ($0.10/hr for 3-replica control plane) |
| Use case | Dev/learning | Production |

We use regional for learning purposes to see how it works.

---

### 5.2 Node Locations — Static Zone Pinning

```hcl
node_locations = ["us-central1-a", "us-central1-b", "us-central1-c"]
```

**Why this matters for Terraform:**
GKE would pick zones automatically, but Terraform needs to know at plan-time which zones
exist because the `load_balancer` module uses `for_each` with zone names as keys.
`for_each` requires all keys to be known before `terraform apply` runs.

If you don't pin zones, GKE returns zone names only after the cluster is created
(they're "unknown" during plan), making `for_each` fail with:

```
Error: Invalid for_each argument
The "for_each" value depends on resource attributes that cannot be determined
until apply, so Terraform cannot predict how many instances will be created.
```

By setting `node_locations` explicitly, zone names are hard-coded in the variable — known at plan time.

---

### 5.3 VPC-Native Networking

```hcl
ip_allocation_policy {
  cluster_secondary_range_name  = "gke-pods"     # pod IPs from this range
  services_secondary_range_name = "gke-services" # ClusterIP from this range
}
```

This tells GKE: "use the subnet's secondary ranges for pod and service IPs."
This enables VPC-native (Alias IP) networking — see [Section 14](#14-internal-cluster-networking)
for the full explanation of how this works inside the cluster.

---

### 5.4 Private Cluster Configuration

```hcl
private_cluster_config {
  enable_private_nodes    = true   # nodes have NO public IP
  enable_private_endpoint = false  # kubectl from internet is still allowed
  master_ipv4_cidr_block  = "172.16.0.0/28"
}
```

**`enable_private_nodes = true`:**
Worker nodes (the VMs that run your pods) get only internal IPs from `10.10.0.0/24`.
They cannot be reached directly from the internet.

- Pros: Smaller attack surface — a compromised pod can't easily phone home to attacker infra
- Traffic to Google APIs (Artifact Registry, etc.) goes through `private_ip_google_access`
- Internet egress requires Cloud NAT (not set up here — nodes can reach Google APIs but not arbitrary internet)

**`enable_private_endpoint = false`:**
The Kubernetes API server is still reachable via its public IP.
In production you'd set this to `true` and require a VPN or bastion host.
We keep it `false` here so `kubectl` works from a laptop.

**`master_ipv4_cidr_block = "172.16.0.0/28"`:**
GKE's control plane runs in a separate Google-managed VPC that is VPC-peered into yours.
This `/28` CIDR is reserved inside that peered VPC for the control plane nodes.
It must not overlap with any of your other CIDRs.

The peering is what allows your nodes (10.10.0.x) to talk to the masters (172.16.0.x)
using private IPs — packets go over the VPC peering link, not the internet.

---

### 5.5 Remove Default Node Pool

```hcl
remove_default_node_pool = true
initial_node_count       = 1

node_config {
  disk_type    = "pd-standard"   # HDD, not SSD
  disk_size_gb = 20
}
```

**Why remove the default pool:**
GKE requires at least one node to bootstrap the cluster. It creates a "default-pool"
automatically. We immediately delete it so we can create our own node pool
(`google_container_node_pool`) with precise configuration.

**Why the `node_config` block here:**
Even though the default pool is deleted right after creation, GKE still creates one
temporary node using this cluster-level `node_config`. Without explicitly setting
`disk_type = "pd-standard"`, GKE defaults to `pd-balanced` (SSD), which counts against
the `SSD_TOTAL_GB` quota (250 GB default). That temporary node exhausts the quota before
our real node pool is even created, causing the apply to fail with a quota error.

`pd-standard` uses HDD quota (`DISKS_TOTAL_GB` = 2 TB default) — no quota concern.

---

### 5.6 Workload Identity

```hcl
workload_identity_config {
  workload_pool = "PROJECT_ID.svc.id.goog"
}
```

**What Workload Identity is:**
Normally, code running in a pod would need a GCP Service Account JSON key file to call
GCP APIs. Key files are a security risk — they can be leaked, stolen, and don't expire.

Workload Identity lets a Kubernetes Service Account (KSA) be federated to a GCP Service
Account (GSA). When a pod runs with the right annotations, GKE intercepts metadata API
requests and returns a short-lived token for the GSA instead of the node's SA credentials.

Flow:
```
Pod calls: http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token
                    │
                    ▼ (intercepted by GKE metadata server on the node)
GKE checks: is this pod's K8s SA annotated with a GSA?
                    │
                    ▼ (yes)
Returns: short-lived token for the GSA (not the node SA)
```

This is activated node-by-node with `workload_metadata_config { mode = "GKE_METADATA" }`
in the node pool config.

---

### 5.7 Maintenance Window

```hcl
maintenance_policy {
  recurring_window {
    start_time = "2024-01-01T03:00:00Z"
    end_time   = "2024-01-01T11:00:00Z"
    recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
  }
}
```

GKE auto-upgrades the control plane and nodes (security patches, new Kubernetes versions).
This window says: "you may perform maintenance on Saturdays and Sundays, 03:00–11:00 UTC."

**Why 8 hours, not 4:**
GKE requires at least 48 hours of maintenance availability in any rolling 32-day window.

- 4 hours × 2 days × 4 weekends = 32 hours → **rejected** (< 48h)
- 8 hours × 2 days × 4 weekends = 64 hours → **accepted** (≥ 48h)

---

## 6. GKE Node Pool

**File:** `modules/gke/main.tf` — resource `google_container_node_pool.primary_nodes`

A node pool is a group of identically configured VMs (nodes) that run your workloads.
You can have multiple pools with different machine types (e.g., a CPU pool and a GPU pool).

### 6.1 Node Count

```hcl
location           = "us-central1"   # regional — nodes spread across all 3 zones
initial_node_count = 1               # per zone
```

**Actual node count:** `initial_node_count × number_of_zones = 1 × 3 = 3 total nodes`

One node in `us-central1-a`, one in `us-central1-b`, one in `us-central1-c`.

### 6.2 Autoscaling

```hcl
autoscaling {
  min_node_count = 1
  max_node_count = 3
}
```

These are also **per zone**.
- Minimum: 1 × 3 zones = 3 nodes total
- Maximum: 3 × 3 zones = 9 nodes total

The cluster autoscaler watches for:
- **Pending pods** (no node has capacity) → scales up
- **Underutilized nodes** (could consolidate pods) → scales down after ~10 min

### 6.3 Node Configuration

```hcl
node_config {
  machine_type    = "e2-medium"        # 2 vCPU, 4 GB RAM
  service_account = var.node_service_account
  oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
  disk_type       = "pd-standard"      # HDD
  disk_size_gb    = 80

  workload_metadata_config { mode = "GKE_METADATA" }
  shielded_instance_config {
    enable_secure_boot          = true
    enable_integrity_monitoring = true
  }
  tags = ["gke-node"]   # must match the firewall rule target_tags
}
```

**`e2-medium`:** 2 vCPU (burstable), 4 GB RAM. 3 nodes = 6 vCPU + 12 GB RAM total for the cluster.
Each pod requests 100m CPU + 128 Mi RAM, so you can fit ~20+ pods per node comfortably.

**`service_account`:** The dedicated minimal SA from `module.iam` (not the default Compute SA).
The default SA has Editor access — everything in the project. The minimal SA has only:
`logging.logWriter`, `monitoring.metricWriter`, `monitoring.viewer`, `artifactregistry.reader`.

**`oauth_scopes = ["cloud-platform"]`:** This is a legacy OAuth2 concept that limits what APIs
the node's SA token can call. `cloud-platform` is the broadest scope, but actual access is
controlled by the SA's IAM roles — this is the recommended pattern (broad scope + narrow IAM).

**`disk_type = "pd-standard"`:** Avoids SSD quota consumption.
- 3 zones × 1 node × 80 GB = 240 GB of HDD (DISKS_TOTAL_GB) — safe
- 3 zones × 1 node × 80 GB = 240 GB of SSD (SSD_TOTAL_GB) — would exceed 250 GB quota!

**Shielded nodes:**
- `enable_secure_boot`: Verifies the boot chain using UEFI firmware. Prevents
  a rootkit from loading during boot before the OS security controls are active.
- `enable_integrity_monitoring`: Measures the boot sequence and reports to
  Cloud Monitoring. Alerts if the measurements change (indicating tampering).

**`tags = ["gke-node"]`:** Links nodes to the `allow_gke_control_plane` and
`allow_lb_health_checks` firewall rules via network tag matching.

---

## 7. IAM — Node Service Account

**File:** `modules/iam/main.tf`

### 7.1 Service Account — `google_service_account.gke_node_sa`

```hcl
resource "google_service_account" "gke_node_sa" {
  account_id   = "gke-node-sa-dev"
  display_name = "GKE Node Service Account"
}
```

A GCP Service Account is an identity for a non-human actor (a VM, a container, a pipeline).
It is identified by its email: `gke-node-sa-dev@PROJECT_ID.iam.gserviceaccount.com`.

When GKE nodes are assigned this SA, every call from the node to a GCP API is
authenticated as this SA identity — not as a human user and not as the broad Compute SA.

### 7.2 IAM Roles — `google_project_iam_member` (for_each loop)

```hcl
locals {
  gke_node_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/artifactregistry.reader",
  ]
}
```

**`logging.logWriter`:** GKE's logging agent (fluentd/fluent-bit running as a DaemonSet)
writes pod and system logs to Cloud Logging. Without this role, logs are silently dropped.

**`monitoring.metricWriter`:** GKE's monitoring agent writes CPU, memory, network metrics
to Cloud Monitoring. Used for dashboards, alerts, HPA (Horizontal Pod Autoscaler) metrics.

**`monitoring.viewer`:** Some monitoring sidecars (e.g., Prometheus adaptors) need to
read monitoring data. GKE's own components need this for certain health-check operations.

**`artifactregistry.reader`:** Allows the node to pull container images from
Artifact Registry. When Kubernetes schedules a pod, the node calls `docker pull`
(actually `containerd` pull) to download the image. Without this role, the pull fails
with a 403 Forbidden and the pod stays in `ImagePullBackOff` state.

---

## 8. CI/CD IAM — Artifact Registry + Workload Identity

**File:** `modules/cicd_iam/main.tf`

This module sets up everything GitHub Actions needs to push images and deploy to GKE
**without any stored credentials**.

### 8.1 GCP APIs Enabled

```hcl
google_project_service "artifact_registry"  # artifactregistry.googleapis.com
google_project_service "iam_credentials"    # iamcredentials.googleapis.com
google_project_service "sts"                # sts.googleapis.com
```

GCP APIs are disabled by default and must be explicitly enabled.

- **Artifact Registry API**: Required before you can create a repository or push images.
- **IAM Credentials API**: The API that exchanges a WIF federated token for a
  short-lived Service Account access token. Step 5 in the WIF flow.
- **Security Token Service API**: The API that validates GitHub's OIDC JWT and
  returns a federated identity token. Step 2–4 in the WIF flow.

### 8.2 Artifact Registry Repository — `google_artifact_registry_repository`

```hcl
resource "google_artifact_registry_repository" "app" {
  location      = "us-central1"
  repository_id = "calculator-repo"    # the repo NAME — set in tfvars
  format        = "DOCKER"
}
```

**Why Artifact Registry instead of GCR:**
- GCR (Container Registry) is deprecated and has a provider bug causing apply failures
- GCR uses GCS buckets under the hood — no named repos, no per-repo IAM
- Artifact Registry has named repos, per-repo IAM, cleanup policies, and multi-format support

**Image URL format:**
`us-central1-docker.pkg.dev/PROJECT_ID/calculator-repo/calculator:sha-a1b2c3`

Breaking it down:
- `us-central1-docker.pkg.dev` — the AR hostname for us-central1 region
- `PROJECT_ID` — your GCP project
- `calculator-repo` — the `repository_id` above
- `calculator` — the image name (not in Terraform, just a Docker convention)
- `sha-a1b2c3` — the image tag (set by CI/CD)

### 8.3 CI/CD Service Account — `google_service_account.cicd`

```hcl
resource "google_service_account" "cicd" {
  account_id   = "github-actions-cicd"
}
```

Email: `github-actions-cicd@PROJECT_ID.iam.gserviceaccount.com`

This SA represents the GitHub Actions pipeline in GCP. It only has the minimum
permissions needed: push to AR + deploy to GKE.

### 8.4 IAM: Artifact Registry Writer (repo-scoped)

```hcl
resource "google_artifact_registry_repository_iam_member" "cicd_writer" {
  repository = google_artifact_registry_repository.app.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.cicd.email}"
}
```

**Scoped to the repository (not project-wide):**
The `resource` here is the AR repository, not the project. This means the CI/CD SA can
only push/pull from `calculator-repo`. It has no access to other AR repos, GCS buckets,
Compute instances, or anything else in the project.

This is least-privilege IAM. If GitHub Actions credentials were ever compromised,
an attacker could only push images to one repo — they couldn't delete your cluster
or read your secrets.

### 8.5 IAM: GKE Developer (project-level)

```hcl
resource "google_project_iam_member" "cicd_gke_developer" {
  role   = "roles/container.developer"
  member = "serviceAccount:${google_service_account.cicd.email}"
}
```

`roles/container.developer` allows:
- `kubectl apply` — create/update Kubernetes resources
- `kubectl set image` — update a deployment's image
- `kubectl rollout status` — watch rollout progress
- Does NOT allow: creating GKE clusters, deleting GKE clusters, managing node pools

### 8.6 Workload Identity Pool — `google_iam_workload_identity_pool`

```hcl
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-pool"
}
```

A WIF Pool is a named trust boundary for external identity providers. Think of it as
a container that holds one or more providers (GitHub, AWS, Azure, etc.).
Any provider added to this pool can present tokens to GCP.

The pool itself doesn't grant access — access is controlled by IAM bindings on
specific resources that reference identities from this pool.

### 8.7 Workload Identity Provider — `google_iam_workload_identity_pool_provider`

```hcl
resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = "github-pool"
  workload_identity_pool_provider_id = "github-provider"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.actor"      = "assertion.actor"
    "attribute.ref"        = "assertion.ref"
  }

  attribute_condition = "assertion.repository == 'TamandeepSingh/gke-sample-app'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}
```

**What it does:**
Configures how GitHub's JWT tokens are validated and what GCP attributes they map to.

**GitHub's OIDC JWT claims** (what GitHub puts inside the token):
```json
{
  "sub": "repo:TamandeepSingh/gke-sample-app:ref:refs/heads/main",
  "repository": "TamandeepSingh/gke-sample-app",
  "actor": "TamandeepSingh",
  "ref": "refs/heads/main",
  "sha": "abc123def456",
  "workflow": "CI/CD Pipeline",
  "iss": "https://token.actions.githubusercontent.com"
}
```

**`attribute_mapping`:** Translates JWT claims → GCP attribute names.
`assertion.repository` (GitHub's claim) → `attribute.repository` (GCP's name for it).
These mapped attributes can then be used in IAM conditions.

**`attribute_condition`:**
Only tokens where `assertion.repository == 'TamandeepSingh/gke-sample-app'` are accepted.
This rejects tokens from forks, other repos, and any other workflow not in your repo.
It's evaluated BEFORE the token is accepted — a hard security gate.

**`issuer_uri`:**
GCP fetches GitHub's JWKS (JSON Web Key Set) from this URL and uses the public keys to
verify the JWT signature. If the signature is invalid (token was forged or tampered with),
the whole exchange fails.

### 8.8 WIF IAM Binding — `google_service_account_iam_member`

```hcl
resource "google_service_account_iam_member" "github_wif_binding" {
  service_account_id = google_service_account.cicd.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${pool.name}/attribute.repository/TamandeepSingh/gke-sample-app"
}
```

**What `principalSet://` means:**
This is a special IAM principal syntax that selects a group of identities from a WIF pool.
It says: "all identities in the github-pool where `attribute.repository` equals
`TamandeepSingh/gke-sample-app`".

This is the final gate. The token must have:
1. Passed the `attribute_condition` check in the provider (same repo check)
2. Be a member of this principalSet (same repo check, double-enforced)

`roles/iam.workloadIdentityUser` grants the right to impersonate the CI/CD SA —
specifically the right to call `generateAccessToken` on it.

---

## 9. GCP Load Balancer — All 7 Resources

**File:** `modules/load_balancer/main.tf`

GCP's Global HTTP Load Balancer is composed of several separate resources chained together.
This is unlike a traditional load balancer where you configure everything in one place.

```
Internet ──► Forwarding Rule ──► HTTP Proxy ──► URL Map ──► Backend Service
                                                                    │
                                                            ├── Health Check
                                                            ├── Named Port (zone-a IG)
                                                            ├── Named Port (zone-b IG)
                                                            └── Named Port (zone-c IG)
```

### 9.1 Static External IP — `google_compute_global_address`

```hcl
resource "google_compute_global_address" "lb_ip" {
  name = "dev-gke-lb-ip"
}
```

**Why static:** Without a static address, the LB gets an ephemeral IP that changes
if the forwarding rule is ever recreated. You'd have to update your DNS A record every time.
With a static address, you reserve the IP permanently and the forwarding rule just references it.

**Global address:** Required for global (anycast) load balancers. Regional LBs use regional addresses.

**Anycast:** The same IP is advertised from all of Google's ~160+ Points of Presence worldwide.
A user in Tokyo and a user in London both resolve the same IP, but their traffic goes to
the nearest GCP POP — dramatically lower latency compared to a single-region LB.

### 9.2 Forwarding Rule — `google_compute_global_forwarding_rule`

```hcl
resource "google_compute_global_forwarding_rule" "http" {
  ip_address = google_compute_global_address.lb_ip.address
  port_range = "80"
  target     = google_compute_target_http_proxy.default.id
}
```

The forwarding rule is the **entry point** — the actual "listener". It:
- Owns a specific IP address
- Listens on a specific port (80 for HTTP)
- Forwards packets to a specific HTTP proxy

Every packet arriving at `34.x.x.x:80` is handed to the HTTP proxy.
The forwarding rule does not inspect the HTTP content — that's the proxy's job.

### 9.3 Target HTTP Proxy — `google_compute_target_http_proxy`

```hcl
resource "google_compute_target_http_proxy" "default" {
  url_map = google_compute_url_map.default.id
}
```

The HTTP proxy terminates the HTTP connection (parses HTTP headers) and
consults the URL map to decide where to route the request.

For HTTPS you'd use `google_compute_target_https_proxy` instead, and attach
an SSL certificate resource here. The proxy would then handle TLS termination.

### 9.4 URL Map — `google_compute_url_map`

```hcl
resource "google_compute_url_map" "default" {
  default_service = google_compute_backend_service.default.id
}
```

The URL map is a routing table for HTTP requests. You can route based on:
- **Path**: `/api/*` → backend-service-A, `/static/*` → backend-service-B
- **Host**: `api.example.com` → service-A, `app.example.com` → service-B
- **Headers**, **query parameters**, etc.

Our map has a single `default_service` — everything goes to the same backend.
In a multi-service app you'd add `host_rule` and `path_matcher` blocks.

### 9.5 Backend Service — `google_compute_backend_service`

```hcl
resource "google_compute_backend_service" "default" {
  protocol   = "HTTP"
  port_name  = "http"
  health_checks = [google_compute_health_check.http.id]

  dynamic "backend" {
    for_each = var.instance_group_urls    # map: zone → IG URL
    content {
      group           = backend.value
      balancing_mode  = "UTILIZATION"
      capacity_scaler = 1.0
    }
  }
}
```

The backend service is the "server farm" definition. It contains:
- Which instance groups are the backends (one per zone)
- What protocol to use when talking to backends (HTTP)
- What port name to use (`"http"` — resolved to the actual port via Named Ports)
- Which health check to use
- How to balance load (`UTILIZATION` = based on CPU %)

**`UTILIZATION` vs `RATE`:**
- `UTILIZATION`: Route new requests to the least-CPU-loaded backend. Good for
  CPU-bound apps.
- `RATE`: Route based on requests-per-second capacity. Good for request-bound apps.
  Requires setting `max_rate_per_instance`.

**`capacity_scaler = 1.0`:** Use 100% of each backend's capacity.
Setting to 0.5 would treat the backend as half-capacity (useful for canary deploys
where you want to send less traffic to a new version).

### 9.6 Named Port — `google_compute_instance_group_named_port`

```hcl
resource "google_compute_instance_group_named_port" "http" {
  for_each = var.instance_group_urls   # one resource per zone

  zone  = each.key                     # "us-central1-a"
  group = each.value                   # self-link URL of the IG
  name  = "http"                       # must match backend service's port_name
  port  = 30080                        # the NodePort
}
```

GCP backend services route to named ports, not raw port numbers. The name `"http"` on the
backend service is resolved to port `30080` via this resource. You register the mapping
on each instance group separately.

GKE manages the instance groups (adds/removes nodes as they scale) but does NOT manage
named ports — so it's safe for us to add them externally without conflicting with GKE.

**`each.key` / `each.value`:**
The input `var.instance_group_urls` is a `map(string)`:
```
{
  "us-central1-a" = "https://www.googleapis.com/compute/v1/projects/.../zones/us-central1-a/instanceGroups/gke-..."
  "us-central1-b" = "https://..."
  "us-central1-c" = "https://..."
}
```
`for_each` on a map gives `each.key` = zone name, `each.value` = IG URL.

**`instanceGroups` vs `instanceGroupManagers`:**
The GKE provider returns Instance Group Manager (IGM) URLs:
`...zones/us-central1-a/instanceGroupManagers/gke-cluster-...`

The LB backend service requires Instance Group (IG) URLs:
`...zones/us-central1-a/instanceGroups/gke-cluster-...`

These are different GCP resources. An IGM manages the lifecycle of an IG.
The LB doesn't talk to the IGM — it talks directly to the IG.
The URLs are identical except for the collection segment, so we use:
```hcl
replace(url, "instanceGroupManagers", "instanceGroups")
```
This is done in `modules/gke/outputs.tf` before the URLs are passed to the LB module.

### 9.7 Health Check — `google_compute_health_check`

```hcl
resource "google_compute_health_check" "http" {
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 30080
    request_path = "/"
  }
}
```

GCP's health checkers send HTTP GET requests from `130.211.0.0/22` and `35.191.0.0/16`
to each node on port 30080. The node's kube-proxy forwards this to the pod's `/healthz`.

**Health state machine:**
```
UNKNOWN → HEALTHY (after 2 consecutive 200 responses)
HEALTHY → UNHEALTHY (after 3 consecutive non-200 or timeout)
UNHEALTHY → HEALTHY (after 2 consecutive 200 responses)
```

While a backend is `UNHEALTHY`:
- No new requests are sent to it
- The LB distributes among the remaining healthy backends
- If ALL backends are unhealthy → LB returns 502

The `healthy_threshold` of 2 prevents a backend from flapping in/out of rotation
on a single probe result.

---

## 10. Kubernetes Resources

**Files:** `gke-sample-app/k8s/`

### 10.1 Deployment — `k8s/deployment.yaml`

A Deployment is a Kubernetes controller that manages a set of identical Pods.
It is the "desired state declaration" for your application.

```yaml
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1         # allow 1 extra pod during update (up to 3 pods temporarily)
      maxUnavailable: 0   # never reduce below 2 running pods
```

**Controllers in Kubernetes:**
Kubernetes uses a reconciliation loop. A Deployment controller:
1. Reads the desired state (replicas: 2)
2. Reads the current state (how many pods are actually running)
3. Takes actions to make current = desired (create/delete pods)
4. Repeats forever in the background

**Rolling update with `maxSurge=1, maxUnavailable=0`:**

Sequence when you update the image:
```
Start:  [old-pod-1] [old-pod-2]                   (2 running)
Step 1: [old-pod-1] [old-pod-2] [new-pod-1]       (3 running — surge of 1)
        new-pod-1 passes readiness probe
Step 2: [old-pod-2] [new-pod-1]                   (2 running — old-pod-1 deleted)
Step 3: [old-pod-2] [new-pod-1] [new-pod-2]       (3 running — surge again)
        new-pod-2 passes readiness probe
Step 4: [new-pod-1] [new-pod-2]                   (2 running — old-pod-2 deleted)
```

At no point are there fewer than 2 healthy pods (`maxUnavailable=0`).
There's always at least one pod serving traffic during the update.

**Probes:**
```yaml
livenessProbe:
  httpGet: { path: /healthz, port: 8080 }
  initialDelaySeconds: 10   # wait 10s for app to start before probing
  periodSeconds: 15         # probe every 15s

readinessProbe:
  httpGet: { path: /healthz, port: 8080 }
  initialDelaySeconds: 5
  periodSeconds: 10
```

**Liveness probe:** "Is this pod alive?" If this fails, Kubernetes RESTARTS the pod.
Use this for detecting a deadlock or unrecoverable error state.

**Readiness probe:** "Is this pod ready to receive traffic?" If this fails, Kubernetes
REMOVES the pod from the Service's endpoint list (no traffic) but does NOT restart it.
Use this to hold traffic until the app has fully started (loaded caches, connected to DB, etc.)

The distinction matters: a pod can be alive (not in deadlock) but not ready (still warming up).
During a rolling update, readiness gates ensure the new pod is ready before the old one is killed.

**Resources:**
```yaml
resources:
  requests:
    cpu: "100m"    # 0.1 vCPU = 10% of one core
    memory: "128Mi"
  limits:
    cpu: "250m"    # max 0.25 vCPU before throttling
    memory: "256Mi"
```

`requests` = what the scheduler reserves. A node with 2000m CPU available can fit 20 pods
requesting 100m each.

`limits` = the hard cap. If a pod tries to use more than 250m CPU, Linux's cgroup throttles it.
If it tries to use more than 256Mi memory, Linux OOM-kills the process and Kubernetes restarts the pod.

---

### 10.2 Service — `k8s/service.yaml`

```yaml
spec:
  type: NodePort
  selector:
    app: calculator
  ports:
    - port: 80          # cluster-internal port
      targetPort: 8080  # container port (gunicorn)
      nodePort: 30080   # external port on every node
```

**Why Services exist:**
Pods are ephemeral. When a pod dies and Kubernetes recreates it, it gets a new IP address.
If other components pointed to the old IP, they'd break. A Service provides a stable
virtual IP (ClusterIP) that always routes to currently-healthy pods.

**Service types:**
| Type | Accessibility | Use case |
|------|--------------|---------|
| `ClusterIP` | Inside cluster only | Microservice-to-microservice |
| `NodePort` | External via node IP + port | Dev, or custom external LB |
| `LoadBalancer` | External via dedicated LB IP | Simple apps (costs $) |
| `ExternalName` | Maps to external DNS | Wrapping external services |

**Why `NodePort` (not `LoadBalancer`):**
If you use `LoadBalancer` type, GKE would provision a separate GCP Network Load Balancer
per Service (a passthrough L4 LB). That costs extra money and only works at L4 (can't do
path-based routing, HTTPS termination, etc.).

Our Terraform module already provisions a Global HTTP L7 Load Balancer that routes to
`NodePort 30080`. This is more capable (L7 routing, global anycast) and avoids the
per-service LB cost.

**Port flow:**
```
GCP LB → port 30080 on any node
  kube-proxy → selects a healthy pod (by Service selector: app=calculator)
    forwards to pod port 8080
      gunicorn handles the request
```

**kube-proxy and iptables:**
kube-proxy runs on every node and watches the Kubernetes API for Service and Endpoints changes.
For each NodePort service, it programs `iptables` rules on the node:

```
Packet arrives: TCP dst=10.10.0.2:30080
iptables PREROUTING: match dst_port=30080
  → DNAT: rewrite dst to one of the pod IPs (e.g. 10.20.0.5:8080)
  → route packet to pod IP
```

The pod can be on the same node or a different node. If it's on a different node,
the packet is forwarded via the VPC's internal routing (possible because pod IPs are
from the subnet's secondary range, which GCP routes know about).

---

## 11. The Flask Application

**Files:** `gke-sample-app/app/`

### 11.1 `app.py`

```python
app = Flask(__name__)

@app.route("/")           → shows the form (GET)
@app.route("/calculate")  → processes form submission (POST)
@app.route("/healthz")    → returns "ok", 200 (K8s health probe)
```

**Why port 8080 (not 80):**
Port 80 requires root privileges on Linux. Containers should never run as root.
Port 8080 is the convention for non-root containerized HTTP apps.

**Why `/healthz`:**
Kubernetes probes and the GCP LB health check both call this endpoint.
It must respond with HTTP 200 within `timeout_sec` (5s) or the probe fails.
No heavy logic — just a `return "ok", 200`.

### 11.2 `Dockerfile` + gunicorn

The Dockerfile (from the project) builds a Python container and uses `gunicorn` to serve
the app. Gunicorn is a production WSGI server.

**Flask dev server vs gunicorn:**
- Flask's built-in server (`app.run()`) is single-threaded, single-process.
  It can only handle one request at a time — terrible for concurrent users.
- Gunicorn spawns multiple worker processes (typically `2 × CPU + 1`).
  Each worker handles one request at a time, so with 2 CPUs you get ~5 concurrent requests.
  Workers share nothing — each has its own memory space.

**Why the `if __name__ == "__main__":` block is skipped in production:**
When gunicorn imports `app.py`, `__name__` is `"app"` (the module name), not `"__main__"`.
So the `app.run()` block is never executed. Gunicorn manages its own server lifecycle.

---

## 12. CI/CD Pipeline

**File:** `gke-sample-app/.github/workflows/ci-cd.yml`

### 12.1 Trigger

```yaml
on:
  push:
    branches: [main]        # full pipeline: test + build + deploy
  pull_request:
    branches: [main]        # test only (no build, no deploy)
```

On a PR, only the `test` job runs — fast feedback without building Docker images.
On a merge to main, all three jobs run sequentially.

### 12.2 Job 1: Test

```
Runner: ubuntu-latest (fresh VM)
Steps:
  1. Checkout code
  2. Set up Python 3.12 (with pip cache)
  3. pip install requirements + pytest
  4. pytest tests/ -v
```

No GCP auth needed. This job is pure Python testing. It fails fast if any test fails,
preventing a broken image from being built and pushed.

### 12.3 Job 2: Build & Push

```
Runner: fresh ubuntu-latest VM (no shared state with Job 1)
Steps:
  1. Checkout code
  2. Compute image tag: sha-$(git rev-parse --short HEAD)
  3. Authenticate to GCP via WIF
  4. Configure Docker credential helper for AR hostname
  5. Set up Docker Buildx (for cache support)
  6. Build + push: IMAGE:sha-abc  and  IMAGE:latest
```

**WIF Auth in detail:**
```yaml
- uses: google-github-actions/auth@v2
  with:
    workload_identity_provider: ${{ secrets.WIF_PROVIDER }}
    service_account: ${{ secrets.WIF_SERVICE_ACCOUNT }}
    token_format: access_token
```

Internally this action:
1. Requests a GitHub OIDC token (JWT) from GitHub's token service
2. Sends the JWT to `https://sts.googleapis.com/v1/token` (GCP Security Token Service)
3. GCP validates the JWT signature, evaluates `attribute_condition`
4. Returns a federated identity token
5. Uses the federated token to call `https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/...generateAccessToken`
6. Returns a short-lived OAuth2 access token for the CI/CD SA
7. Sets `GOOGLE_APPLICATION_CREDENTIALS` env var so gcloud + Docker can use it

`token_format: access_token` is required in the build job because `gcloud auth configure-docker`
needs an actual OAuth2 token, not just the Application Default Credentials file.

**Docker credential helper:**
```bash
AR_HOSTNAME=$(echo "${{ secrets.AR_REGISTRY }}" | cut -d'/' -f1)
# AR_REGISTRY = "us-central1-docker.pkg.dev/PROJECT/calculator-repo"
# cut -d'/' -f1 extracts "us-central1-docker.pkg.dev"
gcloud auth configure-docker "$AR_HOSTNAME" --quiet
```

This adds an entry to `~/.docker/config.json`:
```json
{
  "credHelpers": {
    "us-central1-docker.pkg.dev": "gcloud"
  }
}
```

Every `docker push` to `us-central1-docker.pkg.dev` now calls `docker-credential-gcloud`
to get a fresh OAuth2 token automatically. Without this, `docker push` would fail with
an authentication error.

**SHA tagging:**
```bash
echo "tag=sha-$(git rev-parse --short HEAD)" >> $GITHUB_OUTPUT
```
Produces a tag like `sha-a1b2c3d` (7-character git short SHA).

Why SHA tags instead of `latest`:
- `latest` is mutable — any push overwrites it. If two pushes happen close together,
  the deploy job might pick up the wrong build.
- SHA tags are immutable. `sha-a1b2c3d` always refers to exactly one image build.
- Rollback: `kubectl set image deployment/calculator calculator=IMAGE:sha-previous` is precise.

### 12.4 Job 3: Deploy

```
Runner: fresh ubuntu-latest VM (no shared state with Job 2)
Steps:
  1. Checkout code
  2. Authenticate to GCP via WIF (fresh token needed — different VM)
  3. Get GKE credentials (writes kubeconfig to ~/.kube/config)
  4. kubectl apply -f k8s/     (apply deployment.yaml + service.yaml)
  5. kubectl set image deployment/calculator calculator=IMAGE:sha-abc
  6. kubectl rollout status deployment/calculator --timeout=120s
```

**Why auth is done again:**
Each GitHub Actions job runs on a completely fresh VM. There is no shared filesystem,
no shared environment variables, and no shared credentials between jobs.
The WIF token from Job 2 is gone — Job 3 must authenticate independently.

**`kubectl apply -f k8s/`:**
This is idempotent — if resources already exist, it patches them with any changes.
If they don't exist, it creates them. Running this on every deploy keeps the cluster
in sync with the manifests checked into git.

**`kubectl rollout status --timeout=120s`:**
Blocks the job until all pods pass their readiness probe. If any pod fails
(bad image, app crash, probe timeout), this command exits non-zero, failing the job.
The deployment stays at the previous version (Kubernetes does not auto-rollback —
`kubectl rollout undo deployment/calculator` is the manual rollback command).

---

## 13. Complete Network Path: User → Pod → User

This is the full journey of a single HTTP GET request from a user's browser.

```
Browser: GET http://34.102.x.x/ HTTP/1.1
         Host: 34.102.x.x
```

### Step 1 — DNS Resolution (if using a domain)

If a DNS A record points to the LB's static IP, the browser queries DNS.
Otherwise, the user types the raw IP directly. Either way, the result is the
IP address of the GCP Global Load Balancer (`34.102.x.x`).

**Anycast routing:** The same IP is announced from all GCP Points of Presence.
BGP routing ensures the user's ISP routes to the nearest POP.
A user in Singapore hits a Singapore POP; a user in Frankfurt hits a Frankfurt POP.
From the POP, Google's private backbone carries the packet to `us-central1`.

### Step 2 — TCP Connection to GCP Forwarding Rule

The browser opens a TCP connection to `34.102.x.x:80`.

The packet arrives at the **Forwarding Rule** (`google_compute_global_forwarding_rule`).
The forwarding rule is the "listener" — it just sees: "TCP packet on my IP on port 80."
It hands the packet to the HTTP Proxy.

### Step 3 — HTTP Proxy + URL Map

The **Target HTTP Proxy** (`google_compute_target_http_proxy`) parses the HTTP headers.
It reads the `Host` header and the request path `/` and consults the **URL Map**.

The URL Map has one rule: everything → `default` backend service.
URL map returns the backend service ID.

### Step 4 — Backend Service + Load Balancing Decision

The **Backend Service** (`google_compute_backend_service`) makes the actual routing decision:
- Which instance group should receive this request?
- Which specific node within that group?

It checks health status of all backends across the 3 zones.
It picks a zone (e.g., `us-central1-a`) based on `UTILIZATION` balancing mode.
Within the zone's instance group, it picks a specific node using round-robin.

The chosen backend: `Node-1 in us-central1-a`, IP `10.10.0.2`.
The backend service knows to send traffic to port `30080` (via the Named Port `"http"`).

### Step 5 — Packet Leaves GCP LB Infrastructure

GCP rewrites the destination IP to the chosen node's internal IP: `10.10.0.2:30080`.
The packet is now traveling inside GCP's internal network to the GKE node.

The source IP at this point is in `130.211.0.0/22` or `35.191.0.0/16`
(GCP's proxy IP ranges) — not the user's original IP. The original client IP is
preserved in the `X-Forwarded-For` HTTP header.

### Step 6 — Firewall Evaluation on the Node

The packet arrives at the GKE node's network interface (`10.10.0.2`).
GCP's VPC firewall evaluates rules for this packet:

- Source: `130.211.0.x` (LB health-check/proxy range)
- Destination port: `30080`
- Node has tag: `gke-node`

Matches rule: `allow_lb_health_checks` (source_ranges + target_tag + port).
**Packet allowed** — enters the node's network stack.

### Step 7 — kube-proxy iptables DNAT

On the node, the packet hits the Linux `iptables` PREROUTING chain.
`kube-proxy` has programmed a rule for NodePort 30080:

```
iptables -t nat -A KUBE-NODEPORTS -p tcp --dport 30080 -j KUBE-SVC-<hash>
```

The `KUBE-SVC` chain implements load balancing using probabilistic rules:
```
50%: DNAT to Pod-1 at 10.20.0.5:8080
50%: DNAT to Pod-2 at 10.20.0.8:8080
```

Let's say it picks Pod-1 at `10.20.0.5:8080`.
iptables rewrites: `dst 10.10.0.2:30080` → `dst 10.20.0.5:8080`

### Step 8 — Routing to the Pod

**Case A — Pod is on this same node (us-central1-a, Node-1):**
The packet is delivered via the local virtual network interface (a `veth` pair).
No network hop needed.

**Case B — Pod is on a different node (e.g., us-central1-b, Node-2):**
The packet's destination `10.20.0.5` is in the `10.20.0.0/16` pod range.
GCP's VPC knows that `10.20.x.x` addresses are on specific nodes
(this routing is managed by GKE's VPC-native networking — pod CIDRs are
announced as routes attached to each node).
The packet is forwarded via the subnet's internal router to Node-2 (`10.10.0.3`),
which then delivers it to the pod.

### Step 9 — Pod Receives the Packet

The packet arrives at the pod's network interface (`eth0` inside the container).
Port `8080` is listening — gunicorn accepts the TCP connection.

Gunicorn passes the request to Flask:
- Flask's `@app.route("/")` handler fires
- `render_template("index.html", result=None, error=None)` is called
- Jinja2 renders the HTML template with the provided context variables
- Flask returns an HTTP 200 response with the rendered HTML

### Step 10 — Response Travels Back

The response follows the reverse path:
```
Pod (10.20.0.5) → [iptables SNAT: rewrite src] → Node-1 (10.10.0.2)
→ GCP backend service proxy → Forwarding Rule IP (34.102.x.x)
→ GCP POP → Internet → User's browser
```

**Total hop count:** ~8 logical hops (DNS → Anycast → GCP network → Forwarding Rule
→ HTTP Proxy → Backend Service → Node iptables → Pod)

**Typical latency breakdown:**
- Internet (user → nearest GCP POP): 5–50ms depending on user location
- GCP backbone (POP → us-central1): 10–50ms depending on POP
- GCP internal (LB → node → pod): <1ms
- Flask response time: <5ms for a simple template render
- Return trip: similar to forward trip

**Total: ~30–150ms** for most users globally.

---

## 14. Internal Cluster Networking

### 14.1 VPC-Native Pod Networking

In VPC-native mode, each GKE node is allocated a `/24` slice of the `gke-pods` range:
```
Node-1 (us-central1-a): pods get IPs from 10.20.0.0/24   (256 pod IPs)
Node-2 (us-central1-b): pods get IPs from 10.20.1.0/24   (256 pod IPs)
Node-3 (us-central1-c): pods get IPs from 10.20.2.0/24   (256 pod IPs)
```

When GKE assigns a `/24` to a node, it also creates a GCP **alias IP route** on the node's
network interface. The VPC routing table then knows: "traffic to `10.20.0.0/24` → Node-1."

This means pod-to-pod traffic across nodes is **direct** — no encapsulation (VXLAN/IPIP),
no tunnels. The VPC's native router handles it. This is faster and simpler than
overlay networking (used in non-VPC-native clusters).

### 14.2 Virtual Ethernet Pairs (veth)

Each pod gets a network namespace (isolated IP stack) connected to the node via a `veth` pair:

```
Node network namespace          Pod network namespace
(10.10.0.2)                    (10.20.0.5)
┌─────────────────────┐         ┌──────────────────────┐
│  veth0 ──────────────────────── eth0                 │
│  (node end)         │         │  IP: 10.20.0.5/24    │
│  bridge: cbr0       │         │  GW: 10.20.0.1       │
└─────────────────────┘         └──────────────────────┘
```

A `veth` pair is like a virtual Ethernet cable with one end in the pod and one end on the node.
The node end connects to a bridge (`cbr0`). All pod traffic goes through the bridge and then
through the node's main `eth0` into the VPC.

### 14.3 Service ClusterIP + kube-proxy

When you create a Kubernetes Service, the control plane assigns it a **ClusterIP** from the
`gke-services` range (`10.30.0.0/20`). For example, the `calculator` Service might get `10.30.0.5`.

This IP is **virtual** — no actual network interface has it. kube-proxy makes it work:

```
Pod calls: 10.30.0.5:80 (Service ClusterIP)
                │
         iptables KUBE-SERVICES chain
                │
         KUBE-SVC-CALCULATOR chain
                │
     50%   KUBE-SEP-POD1   50%   KUBE-SEP-POD2
     DNAT to 10.20.0.5:8080  DNAT to 10.20.0.8:8080
```

kube-proxy watches the Kubernetes API. When pods come and go, kube-proxy updates
the iptables rules to add/remove pod endpoints. This happens within ~1 second of
a pod starting or stopping.

### 14.4 DNS (CoreDNS)

CoreDNS runs as a Deployment in the `kube-system` namespace.
Every pod has `/etc/resolv.conf` configured to use CoreDNS as its DNS server.

When your app calls `http://calculator/` (Service name, no port), DNS resolves:
```
calculator.default.svc.cluster.local → 10.30.0.5 (ClusterIP)
```

Short name search path in `/etc/resolv.conf`:
```
search default.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.30.0.10   (CoreDNS ClusterIP)
```

CoreDNS serves records from two sources:
1. `kubernetes` plugin: reads Kubernetes API for Services and Pods
2. Forward: passes unknown queries to GCP's DNS (169.254.169.254) for external names

---

## 15. IAM & Security Architecture

### 15.1 Two Service Account Architecture

```
Service Account 1: gke-node-sa-dev@PROJECT.iam.gserviceaccount.com
  Used by: GKE node VMs
  Roles:
    roles/logging.logWriter         → write logs to Cloud Logging
    roles/monitoring.metricWriter   → write metrics to Cloud Monitoring
    roles/monitoring.viewer         → read monitoring data
    roles/artifactregistry.reader   → pull container images

Service Account 2: github-actions-cicd@PROJECT.iam.gserviceaccount.com
  Used by: GitHub Actions pipeline
  Roles:
    roles/artifactregistry.writer   (repo-scoped, not project-wide)  → push images
    roles/container.developer       (project-level)                  → kubectl deploy
```

Neither SA has `roles/owner`, `roles/editor`, or `roles/viewer` (broad roles).
Blast radius is minimized — a compromised node SA can't deploy or delete clusters.
A compromised CI/CD SA can't read secrets or modify cluster configuration.

### 15.2 WIF Token Exchange Flow (7 Steps)

```
1. GitHub Actions runner starts
   │
   ▼
2. Runner requests OIDC token from GitHub's token service
   GitHub signs a JWT with claims: { repository, actor, ref, sha, ... }
   JWT is valid for ~10 minutes
   │
   ▼
3. google-github-actions/auth sends JWT to:
   POST https://sts.googleapis.com/v1/token
   Body: { audience, grant_type, subject_token_type, subject_token=<jwt> }
   │
   ▼
4. GCP STS validates:
   a. JWT signature (using GitHub's public JWKS from https://token.actions.githubusercontent.com/.well-known/jwks)
   b. JWT issuer matches oidc.issuer_uri
   c. attribute_condition: assertion.repository == 'TamandeepSingh/gke-sample-app'
   │
   ▼
5. GCP STS returns a federated identity token
   This token represents: "a principal from the github-pool with attribute.repository=TamandeepSingh/gke-sample-app"
   │
   ▼
6. auth action calls:
   POST https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/github-actions-cicd@.../generateAccessToken
   Authorization: Bearer <federated_token>
   │
   GCP IAM checks: does the federated principal have roles/iam.workloadIdentityUser on the SA?
   The principalSet binding from Step 8.8 grants this.
   │
   ▼
7. IAM Credentials API returns:
   { "accessToken": "ya29...", "expireTime": "2024-01-01T00:10:00Z" }

   This OAuth2 access token:
   - Is scoped to github-actions-cicd@... SA's permissions
   - Expires when the job ends (~1 hour max)
   - Was never stored anywhere — it exists only in the runner's memory
```

### 15.3 Why No SA Key Files

Org policy `constraints/iam.disableServiceAccountKeyCreation` is enabled on the GCP organization.
This policy prevents anyone from creating downloadable JSON key files for service accounts.

SA key files are a security liability:
- They don't expire (unless you manually rotate them)
- If committed to git, they're public forever (git history)
- Tools like Trufflehog and GitHub secret scanning alert on them, but only after they're already leaked
- Rotating them requires updating secrets in every system that uses them

WIF eliminates all these problems: no key file exists, nothing to rotate, nothing to leak,
tokens expire automatically.

---

## Quick Reference: All IP Ranges

| Range | CIDR | Purpose |
|-------|------|---------|
| Node subnet | `10.10.0.0/24` | GKE worker nodes, GCE VMs |
| Pod IPs | `10.20.0.0/16` | Kubernetes pods |
| Service IPs (ClusterIP) | `10.30.0.0/20` | Kubernetes Services |
| Control plane (GKE-managed) | `172.16.0.0/28` | GKE master nodes (VPC peering) |
| GCP LB health check sources | `130.211.0.0/22`, `35.191.0.0/16` | Must be allowed by firewall |

## Quick Reference: All Ports

| Port | Protocol | Used by | Firewall rule |
|------|----------|---------|---------------|
| 80 | TCP | GCE web-server VM | `allow_http_ssh` |
| 22 | TCP | SSH to GCE VM | `allow_http_ssh` |
| 443 | TCP | GKE webhook admission controllers | `allow_gke_control_plane` |
| 10250 | TCP | GKE kubelet API (kubectl logs/exec) | `allow_gke_control_plane` |
| 30080 | TCP | Kubernetes NodePort for calculator | `allow_lb_health_checks` |
| 8080 | TCP | Flask/gunicorn inside pod | (no firewall needed, pod-internal) |

## Quick Reference: All GitHub Secrets

| Secret | Value source | Used in |
|--------|-------------|---------|
| `GCP_PROJECT_ID` | GCP project ID | Deploy job |
| `WIF_PROVIDER` | `terraform output -raw cicd_wif_provider` | Build + Deploy |
| `WIF_SERVICE_ACCOUNT` | `terraform output -raw cicd_wif_service_account` | Build + Deploy |
| `AR_REGISTRY` | `terraform output -raw cicd_registry_url` | Build job |
| `GKE_CLUSTER_NAME` | `terraform output -raw gke_cluster_name` | Deploy job |
| `GKE_CLUSTER_ZONE` | Region: `us-central1` | Deploy job |
