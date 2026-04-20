# Terraform Learning — GKE Infrastructure on GCP

This project provisions the complete GCP infrastructure for a Kubernetes-based application using Terraform. It works alongside [gke-sample-app](../gke-sample-app) which deploys onto this infrastructure.

## What this project teaches

| Concept | Where |
|---|---|
| Terraform module pattern | `modules/*/` |
| VPC and private networking | `modules/vpc/` |
| GKE cluster (regional, private, Workload Identity) | `modules/gke/` |
| GCE virtual machine | `modules/gce/` |
| IAM and least-privilege service accounts | `modules/iam/` |
| Global HTTP Load Balancer | `modules/load_balancer/` |
| Cloud Logging export sink | `modules/logging/` |
| Keyless CI/CD auth (Workload Identity Federation) | `modules/cicd_iam/` |
| GCR image registry | `modules/cicd_iam/` |
| Terraform remote state (GCS backend) | `environments/dev/backend.tf` |

---

## Architecture

```
                        ┌─────────────────────────────────────────────────────┐
                        │  GCP Project                                         │
                        │                                                      │
  Developer             │  ┌──────────────────────────────────────────────┐   │
  terraform apply ──────►  │  VPC  (10.10.0.0/24)                         │   │
                        │  │                                              │   │
                        │  │  ┌─────────────────────────────────────────┐│   │
                        │  │  │  Subnet                                 ││   │
                        │  │  │  ├─ Primary:   10.10.0.0/24  (nodes)   ││   │
                        │  │  │  ├─ Secondary: 10.20.0.0/16  (pods)    ││   │
                        │  │  │  └─ Secondary: 10.30.0.0/20  (services)││   │
                        │  │  └─────────────────────────────────────────┘│   │
                        │  │                                              │   │
                        │  │  ┌──────────────┐  ┌──────────────────────┐ │   │
                        │  │  │  GCE VM      │  │  GKE Cluster         │ │   │
                        │  │  │  (Apache)    │  │  (regional, 3 zones) │ │   │
                        │  │  │  port 80     │  │  ┌────┐ ┌────┐ ┌────┐│ │   │
                        │  │  └──────────────┘  │  │Pod │ │Pod │ │Pod ││ │   │
                        │  │                    │  └────┘ └────┘ └────┘│ │   │
                        │  │                    │  NodePort: 30080      │ │   │
                        │  │                    └──────────────────────┘ │   │
                        │  └──────────────────────────────────────────────┘   │
                        │                              ▲                       │
  Internet ─────────────►  Global HTTP Load Balancer  │                       │
  (port 80)             │  (anycast static IP)        │                       │
                        │  routes to NodePort 30080 ──┘                       │
                        │                                                      │
                        │  ┌──────────────────────────────────────────────┐   │
                        │  │  IAM                                          │   │
                        │  │  ├─ GKE node SA  (logging, monitoring, AR)   │   │
                        │  │  └─ CI/CD SA     (GCR push, GKE deploy)      │   │
                        │  └──────────────────────────────────────────────┘   │
                        │                                                      │
                        │  ┌──────────────────────────────────────────────┐   │
                        │  │  Workload Identity Federation                 │   │
                        │  │  GitHub OIDC token ──► short-lived GCP token  │   │
                        │  │  No SA keys stored anywhere                   │   │
                        │  └──────────────────────────────────────────────┘   │
                        │                                                      │
                        │  Cloud Logging ──► GCS bucket (WARNING+ logs)        │
                        │  GCR            ──► stores Docker images              │
                        └─────────────────────────────────────────────────────┘
```

---

## Project structure

```
Terraform-learning/
├── environments/
│   └── dev/
│       ├── main.tf           # Composition layer — wires all modules together
│       ├── variables.tf      # Variable declarations
│       ├── terraform.tfvars  # Actual values (project ID, region, etc.)
│       └── backend.tf        # Remote state in GCS
├── modules/
│   ├── vpc/                  # VPC, subnet, secondary ranges, firewall rules
│   ├── gke/                  # GKE cluster, node pool, Workload Identity
│   ├── gce/                  # Compute Engine VM (Apache web server)
│   ├── iam/                  # GKE node service account (least-privilege)
│   ├── load_balancer/        # Global HTTP LB, backend service, health check
│   ├── logging/              # Cloud Logging sink → GCS
│   └── cicd_iam/             # CI/CD SA, GCR, Workload Identity Federation
└── shared/
    └── variables.tf          # Shared variable definitions (reference)
```

---

## Module dependency graph

```
module.iam         ──── gke_node_sa_email ────────────────► module.gke
module.vpc         ──── vpc_name, subnet_name, ranges ────► module.gke
module.vpc         ──── vpc_id, subnet_id ────────────────► module.gce
module.gke         ──── instance_group_url_map ───────────► module.load_balancer
module.vpc         ──── vpc_name ─────────────────────────► module.load_balancer
module.cicd_iam    ──── (outputs → GitHub Secrets) ───────► CI/CD pipeline
```

`module.iam`, `module.vpc`, and `module.cicd_iam` have no dependencies and run in parallel. Everything else waits on its inputs.

---

## Modules

### `modules/vpc`
Creates the network foundation everything else attaches to.
- Custom VPC (no auto-subnets)
- Regional subnet with primary CIDR for nodes/VMs
- Two secondary ranges for GKE VPC-native networking (pods + services)
- `private_ip_google_access` enabled so private nodes reach Google APIs
- Firewall: HTTP/SSH inbound, GKE control-plane-to-node communication

### `modules/gke`
Provisions the Kubernetes cluster.
- Regional cluster (control plane replicated across 3 zones — high availability)
- Private nodes (no public IPs), public API server endpoint
- Workload Identity enabled (pods can act as GCP service accounts without key files)
- Node pool with autoscaling, auto-repair, auto-upgrade, shielded nodes
- `node_locations` pinned explicitly so zone names are known at plan time (required for the load balancer `for_each`)

### `modules/gce`
A single Compute Engine VM running Apache — used to learn VM provisioning basics alongside GKE.

### `modules/iam`
Creates a minimal service account for GKE worker nodes.
- `roles/logging.logWriter` — write logs
- `roles/monitoring.metricWriter` — write metrics
- `roles/monitoring.viewer` — read monitoring data
- `roles/artifactregistry.reader` — pull images

### `modules/load_balancer`
Global HTTP Load Balancer in front of the GKE cluster.
- Static anycast external IP
- Backend service pointing to GKE instance groups (one per zone)
- HTTP health check on `/healthz`
- Named port `http` registered on each zonal instance group
- Firewall rule allowing GCP health-checker IPs to reach nodes

### `modules/logging`
Exports Cloud Logging entries to GCS for long-term retention.
- Log sink with unique writer identity
- Filter: `severity >= WARNING` in dev (change to `""` for all logs)

### `modules/cicd_iam`
Everything the CI/CD pipeline needs to operate without stored credentials.
- Enables APIs: `containerregistry`, `iamcredentials`, `sts`
- GCR registry initialised for the project
- GitHub Actions service account with `storage.admin` (GCR) and `container.developer` (GKE)
- Workload Identity Pool + GitHub OIDC Provider
- IAM binding: only the specific GitHub repo can impersonate the CI/CD SA

---

## Setup

### Prerequisites
- GCP project with billing enabled
- `gcloud` CLI authenticated (`gcloud auth application-default login`)
- Terraform >= 1.5.0
- A GCS bucket for Terraform state (update `environments/dev/backend.tf`)

### 1. Update variables

Edit [environments/dev/terraform.tfvars](environments/dev/terraform.tfvars):

```hcl
project_id  = "your-actual-project-id"
region      = "us-central1"
github_repo = "your-github-username/gke-sample-app"
```

### 2. Initialize and apply

```bash
cd environments/dev

terraform init
terraform plan
terraform apply
```

### 3. Get GitHub Secrets values from Terraform outputs

After apply, run these to get the exact values to paste into GitHub Secrets:

```bash
terraform output -raw cicd_wif_provider        # → WIF_PROVIDER secret
terraform output -raw cicd_wif_service_account # → WIF_SERVICE_ACCOUNT secret
terraform output -raw cicd_gcr_registry_url    # → update IMAGE in ci-cd.yml
```

### 4. Configure kubectl

```bash
# The exact command is printed as a Terraform output
terraform output -raw gke_get_credentials
# Run the printed command, e.g.:
gcloud container clusters get-credentials dev-gke-cluster \
  --region us-central1 --project your-project-id
```

---

## Outputs

| Output | Description |
|---|---|
| `vpc_id` | VPC network ID |
| `gke_cluster_name` | GKE cluster name |
| `gke_get_credentials` | `gcloud` command to configure kubectl |
| `vm_external_ip` | Apache VM external IP |
| `load_balancer_ip` | Static external IP — point your DNS A record here |
| `load_balancer_url` | `http://<ip>` — returns 502 until app is deployed |
| `cicd_wif_provider` | **Paste into GitHub Secret: `WIF_PROVIDER`** |
| `cicd_wif_service_account` | **Paste into GitHub Secret: `WIF_SERVICE_ACCOUNT`** |
| `cicd_gcr_registry_url` | Base GCR URL for Docker image paths |

---

## Companion project

**[gke-sample-app](../gke-sample-app)** — the application deployed onto this infrastructure. It contains the Dockerfile, Kubernetes manifests, and the GitHub Actions pipeline that uses the Workload Identity Federation set up here.
