# Architecture & Workflow — GKE Learning Projects

This document covers the complete picture of how both projects work together: from a developer pushing code to the app serving traffic on the internet.

---

## The two projects

| Project | Role |
|---|---|
| [Terraform-learning/](.) | Provisions all GCP infrastructure using Terraform |
| [gke-sample-app/](../gke-sample-app) | The application — containerised, deployed to GKE via CI/CD |

Neither project works in isolation. Terraform creates the platform; the app runs on it.

---

## Full system diagram

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  Developer workstation                                                        │
│                                                                               │
│  ┌───────────────────────┐        ┌──────────────────────────────────────┐   │
│  │  Terraform-learning/  │        │  gke-sample-app/                     │   │
│  │  terraform apply      │        │  git push origin main                │   │
│  └───────────┬───────────┘        └─────────────────┬────────────────────┘   │
└──────────────┼─────────────────────────────────────┼──────────────────────┘
               │ provisions                           │ triggers
               ▼                                      ▼
┌──────────────────────────────┐    ┌─────────────────────────────────────────┐
│  GCP (Infrastructure)         │    │  GitHub Actions (CI/CD)                 │
│                               │    │                                          │
│  VPC + Subnet                 │    │  Job 1: test                            │
│  GKE Cluster (3 zones)        │    │    pytest tests/ -v                     │
│  Global HTTP Load Balancer    │◄───│                                          │
│  Artifact Registry (Docker)   │    │  Job 2: build                           │
│  Workload Identity (WIF)      │◄───│    WIF auth → docker build → AR push   │
│  CI/CD service account        │    │                                          │
│  Cloud Logging → GCS          │    │  Job 3: deploy                          │
│                               │◄───│    WIF auth → kubectl set image         │
└──────────────────────────────┘    └─────────────────────────────────────────┘
               │
               │  traffic
               ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  Internet user  ──►  Global LB (anycast IP)  ──►  GKE NodePort 30080        │
│                                                   ──►  Calculator Pod :8080   │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Infrastructure layer (Terraform-learning)

Terraform provisions all GCP resources declaratively. Running `terraform apply` in `environments/dev/` creates every resource below.

### Modules

```
modules/
├── vpc/        — VPC, subnet, secondary ranges, firewall rules
├── gke/        — GKE cluster + node pool
├── gce/        — Compute Engine VM (Apache — learning resource)
├── iam/        — GKE node service account (least-privilege)
├── load_balancer/ — Global HTTP LB, backend service, health check, named ports
├── logging/    — Cloud Logging sink → GCS
└── cicd_iam/   — Artifact Registry, CI/CD SA, Workload Identity Federation
```

### Network

```
VPC: my-custom-vpc
└── Subnet: my-subnet  (10.10.0.0/24)
    ├── Secondary range: gke-pods      (10.20.0.0/16)  ← pod IPs
    └── Secondary range: gke-services  (10.30.0.0/20)  ← ClusterIP IPs

Firewall rules:
  allow-http-ssh          — port 80 (all), port 22 (allowed CIDRs) → VMs
  allow-gke-control-plane — ports 443, 10250 → GKE nodes
  allow-lb-health-check   — GCP health-checker IPs (130.211.0.0/22, 35.191.0.0/16)
                            → port 30080 on all nodes
```

VPC-native networking (Alias IPs) is required for private clusters and Workload Identity.

### GKE cluster

```
Cluster type: Regional (us-central1)
  ├── Control plane replicated across 3 zones (high availability)
  ├── Node locations: us-central1-a, us-central1-b, us-central1-c (pinned explicitly)
  ├── Private nodes (no public IPs — reach Google APIs via private_ip_google_access)
  ├── Public API server endpoint (kubectl works from anywhere)
  └── Workload Identity enabled (pods authenticate as GCP SAs without key files)

Bootstrap node (temporary):
  ├── remove_default_node_pool = true — deleted immediately after cluster creation
  ├── disk_type = pd-standard (HDD) — avoids consuming SSD quota for a throwaway node
  └── disk_size_gb = 20

Node pool: dev-gke-cluster-node-pool
  ├── Machine: e2-medium (2 vCPU, 4 GB)
  ├── Disk: 80 GB pd-standard (HDD — avoids SSD_TOTAL_GB quota limit of 250 GB)
  ├── Autoscaling: 1–3 nodes per zone (3–9 nodes total across 3 zones)
  ├── Auto-repair + auto-upgrade
  ├── Shielded nodes (secure boot, integrity monitoring)
  └── Maintenance window: Saturday–Sunday 03:00–11:00 UTC
      (8h × 2 days satisfies GKE's ≥48h/32-day maintenance availability requirement)
```

The cluster is regional — if one zone loses nodes, the other two keep serving traffic.

### Load balancer

```
Global HTTP Load Balancer
├── Static anycast external IP  ← point your DNS A record here
├── Forwarding rule: port 80 → HTTP proxy
├── URL map: all paths → backend service
├── Backend service
│   ├── Health check: GET /healthz on port 30080 (10s interval, 5s timeout)
│   └── Backends — one instance group per zone:
│       ├── us-central1-a  instanceGroups/gke-dev-gke-cluster-...-grp
│       ├── us-central1-b  instanceGroups/gke-dev-gke-cluster-...-grp
│       └── us-central1-c  instanceGroups/gke-dev-gke-cluster-...-grp
└── Named port "http" = 30080 registered on each instance group
```

**Important:** GKE's `instance_group_urls` output returns `instanceGroupManagers/...` URLs (IGM self-links). The backend service requires `instanceGroups/...` URLs (IG self-links). The GKE module converts them with `replace(url, "instanceGroupManagers", "instanceGroups")` — the IG and IGM always share the same name.

**Why a Global LB instead of a per-Service LoadBalancer?** One Global LB handles all zones and uses GCP's anycast network (routes each user to the nearest GCP PoP). Per-Service LoadBalancers provision a separate regional LB per Kubernetes Service — more expensive and more limited.

### IAM design

Two service accounts, each with minimum permissions:

```
gke-node-sa-dev@<project>.iam.gserviceaccount.com      (GKE node SA)
├── roles/logging.logWriter          — write pod logs to Cloud Logging
├── roles/monitoring.metricWriter    — write node/pod metrics
├── roles/monitoring.viewer          — read monitoring data
└── roles/artifactregistry.reader    — pull images from Artifact Registry

github-actions-cicd@<project>.iam.gserviceaccount.com  (CI/CD SA)
├── roles/artifactregistry.writer    — push/pull images (scoped to the repo only,
│                                      not project-wide — tighter than storage.admin)
└── roles/container.developer        — kubectl deploy to GKE
```

### Workload Identity Federation (CI/CD auth)

How GitHub Actions authenticates to GCP with no stored credentials:

```
Workload Identity Pool: github-pool
└── Provider: github-provider
    ├── Issuer: https://token.actions.githubusercontent.com
    ├── Attribute mapping:
    │   google.subject       ← assertion.sub        (unique per workflow run)
    │   attribute.repository ← assertion.repository  (e.g. "user/gke-sample-app")
    │   attribute.actor      ← assertion.actor       (GitHub username)
    │   attribute.ref        ← assertion.ref         (branch/tag ref)
    └── Attribute condition:
        assertion.repository == "TamandeepSingh/gke-sample-app"
        (only this exact repo — forks and other repos are rejected at this gate)

IAM binding on the CI/CD SA:
  principalSet://iam.googleapis.com/.../attribute.repository/TamandeepSingh/gke-sample-app
  → roles/iam.workloadIdentityUser
```

Token exchange flow at runtime:

```
1. GitHub runner requests a signed JWT from GitHub  (automatic — no setup)
2. google-github-actions/auth sends JWT to GCP Security Token Service (STS)
3. STS verifies JWT signature against GitHub's OIDC public keys
4. STS checks attribute_condition — rejects if not the correct repo
5. STS returns a short-lived federated identity token
6. IAM exchanges it for an SA access token (scoped to github-actions-cicd)
7. Token is used for the job duration, then expires — nothing is stored
```

### Artifact Registry

```
Repository: us-central1-docker.pkg.dev/<project-id>/calculator-repo
├── Format: DOCKER
├── Location: us-central1 (same region as GKE — fast image pulls, no egress cost)
└── Images:
    ├── calculator:sha-a1b2c3d  ← every push (immutable, traceable to a commit)
    ├── calculator:sha-e4f5g6h
    └── calculator:latest       ← points to the most recent push (mutable)
```

**Why Artifact Registry over GCR?**
- GCR is deprecated (`google_container_registry` Terraform resource has a known provider bug)
- AR has explicit named repositories — the repo name is a Terraform variable (`var.ar_repo_id`)
- AR uses `roles/artifactregistry.writer` scoped to the specific repo (not project-wide `storage.admin`)
- AR supports cleanup policies, multi-format repos, and per-repo IAM
- AR is region-specific — images stored close to GKE cluster = faster pulls

**Docker auth difference from GCR:**
```
GCR: gcloud auth configure-docker               (configures *.gcr.io globally)
AR:  gcloud auth configure-docker REGION-docker.pkg.dev  (must be explicit per hostname)
```

---

## Application layer (gke-sample-app)

A simple Python Flask calculator, containerised and deployed to Kubernetes.

### Application

```
Flask app  (app/app.py)
├── GET  /          → serves the calculator HTML form (Jinja2 template)
├── POST /calculate → performs arithmetic, returns result page
└── GET  /healthz   → returns "ok" (used by K8s liveness/readiness probes)

WSGI server: gunicorn (2 workers)
Container port: 8080
```

### Docker image

```
Base: python:3.12-slim
├── COPY requirements.txt → pip install --no-cache-dir  (cached layer)
├── COPY app/ .
├── USER appuser (non-root — limits blast radius if app process is compromised)
└── CMD ["gunicorn", "--workers", "2", "--bind", "0.0.0.0:8080", "app:app"]
```

Layer ordering matters: dependencies are installed before source code so Docker reuses the `pip install` layer on code-only changes.

**Jinja2 note:** `{% %}` block tags are parsed across the entire file before HTML is rendered. Never put raw Jinja2 block tags (e.g. `{% for %}`) inside HTML `<!-- -->` comments — they are executed even there, causing `TemplateSyntaxError`. Use `{# #}` for Jinja2 comments instead.

### Kubernetes resources

```
Deployment: calculator
├── Replicas: 2
├── Strategy: RollingUpdate (maxSurge=1, maxUnavailable=0)
│   → always keeps 2 healthy pods; briefly runs 3 during an update
├── Image: us-central1-docker.pkg.dev/<project>/calculator-repo/calculator:<sha-tag>
│   ├── Resources: 100m–250m CPU, 128–256 MB RAM
│   ├── Liveness probe:  GET /healthz every 15s (restarts pod if failing)
│   └── Readiness probe: GET /healthz every 10s (removes pod from LB endpoints if failing)
└── imagePullPolicy: Always

Service: calculator
├── Type: NodePort
├── port 80 → targetPort 8080 → nodePort 30080
└── selector: app=calculator
```

---

## CI/CD pipeline

Every `git push` to `main` triggers a three-job pipeline. Pull requests run `test` only.

### Job 1 — test

```
ubuntu-latest runner
└── pip install -r app/requirements.txt pytest
└── pytest tests/ -v
    ├── test_home_page_loads    test_health_check
    ├── test_addition           test_subtraction
    ├── test_multiplication     test_division
    ├── test_division_by_zero   test_invalid_input
    ├── test_negative_numbers   test_decimal_numbers
```

### Job 2 — build (push to main only)

```
ubuntu-latest runner
├── Authenticate to GCP via WIF  (permissions: id-token: write)
│   GitHub OIDC JWT → GCP STS → SA access token (token_format: access_token required
│   so gcloud and Docker can use it as an OAuth2 bearer token)
│
├── gcloud auth configure-docker us-central1-docker.pkg.dev
│   Registers gcloud as a credential helper for that AR hostname.
│   Hostname is extracted from the AR_REGISTRY secret:
│     AR_HOSTNAME=$(echo "$AR_REGISTRY" | cut -d'/' -f1)
│
├── docker build
│   ├── Tags: <AR_REGISTRY>/calculator:sha-<abc>  (immutable — used by deploy job)
│   │         <AR_REGISTRY>/calculator:latest     (mutable — for manual pulls)
│   └── Cache: type=gha (reuses unchanged layers from previous runs)
│
└── docker push both tags to Artifact Registry
```

The SHA tag is `sha-$(git rev-parse --short HEAD)` — passed as a job output to the deploy job.

### Job 3 — deploy (push to main only)

```
ubuntu-latest runner  (fresh VM — no shared state with build job)
├── Authenticate to GCP via WIF  (no token_format needed — only kubectl calls)
├── gcloud container clusters get-credentials → writes kubeconfig
├── kubectl apply -f k8s/     → idempotent — creates/patches Deployment and Service
├── kubectl set image deployment/calculator \
│     calculator=<AR_REGISTRY>/calculator:sha-<abc>
│   → triggers rolling update using the SHA from the build job output
└── kubectl rollout status --timeout=120s
    → waits for all pods to pass readiness probe
    → fails the job if pods don't become healthy (prompts rollback)
```

### Rolling update behaviour

```
Before:   [Pod v1]  [Pod v1]
                    ↓ kubectl set image
During:   [Pod v1]  [Pod v1]  [Pod v2]   ← maxSurge=1 allows one extra pod
                    ↓ v2 passes readiness probe
          [Pod v1]  [Pod v2]              ← v1 is terminated
                    ↓
After:    [Pod v2]  [Pod v2]
```

`maxUnavailable=0` ensures 2 healthy pods serve traffic throughout. Zero downtime.

---

## End-to-end request flow

```
Browser: GET http://<load-balancer-ip>/

1. DNS resolves to the static anycast IP (provisioned by Terraform)

2. GCP Global LB receives the request at the nearest PoP
   - Checks backend health — pods must be passing /healthz readiness probe
   - Selects a backend: us-central1-a, b, or c instance group

3. Request hits a GKE node on NodePort 30080
   - kube-proxy intercepts and forwards to one of the 2 calculator Pods

4. gunicorn in the Pod handles the request
   - Flask routes GET / → index() → render_template → HTML response

5. Browser renders the page; user fills in the form and submits

6. Browser: POST http://<load-balancer-ip>/calculate
   - Same path: LB → node → kube-proxy → Pod
   - Flask routes POST /calculate → calculate() → result HTML
```

---

## Sequence: developer ships a feature

```
Developer
  │
  ├─ writes code, runs: pytest tests/ -v  (locally)
  ├─ git add . && git commit && git push origin main
  │
  │              GitHub Actions
  │              │
  │              ├─ [test]   pytest — 10 tests pass
  │              │
  │              ├─ [build]
  │              │   ├─ WIF: GitHub JWT → GCP STS → SA access token
  │              │   ├─ configure-docker us-central1-docker.pkg.dev
  │              │   ├─ docker build (layers cached — fast)
  │              │   └─ docker push calculator:sha-abc1234 + :latest
  │              │
  │              └─ [deploy]
  │                  ├─ WIF auth (fresh credentials — new VM)
  │                  ├─ get-gke-credentials → kubeconfig
  │                  ├─ kubectl apply -f k8s/  (no-op if manifests unchanged)
  │                  ├─ kubectl set image → rolling update begins
  │                  └─ kubectl rollout status → waits for healthy pods
  │
  ▼
GKE: new pods running the updated image
LB: traffic shifts to new pods automatically (readiness probes gate this)

Total time: ~3–5 minutes from push to live
```

---

## Key design decisions

| Decision | Reason |
|---|---|
| Workload Identity Federation over SA keys | No credentials to leak, rotate, or audit. SA key creation banned by org policy. |
| Regional GKE cluster | Control plane survives single-zone failures. |
| `node_locations` pinned explicitly | Terraform `for_each` requires static map keys — zone names must be known at plan time. |
| `replace(url, "instanceGroupManagers", "instanceGroups")` | GKE returns IGM self-links; LB backend service requires IG self-links — same name, different collection. |
| `pd-standard` (HDD) for GKE nodes | SSD quota (`SSD_TOTAL_GB`) is 250 GB by default. Regional cluster × 3 zones easily exceeds this. HDD quota is 2 TB. |
| Bootstrap node also `pd-standard` + 10 GB | `remove_default_node_pool=true` still creates 1 temporary node before deleting it — must not use SSD. |
| Maintenance window 8h × 2 days | GKE requires ≥ 48h availability in any 32-day window. 4h × 2 × 4 weekends = 32h (rejected). 8h × 2 × 4 = 64h (accepted). |
| Artifact Registry over GCR | GCR is deprecated; `google_container_registry` has a provider bug. AR has named repos, repo-scoped IAM, and cleanup policies. |
| `artifactregistry.writer` scoped to repo | Tighter than the old `storage.admin` at project level (which granted write to all GCS buckets). |
| Global HTTP LB over per-service LoadBalancer | One LB for all zones; anycast routing; cheaper than one LB per Kubernetes Service. |
| SHA image tags for deployment | Every deployment is traceable to an exact commit. Rollbacks target a specific version, not a mutable `:latest`. |
| `maxUnavailable=0` rolling update | Zero downtime — always `replicas` healthy pods during an update. |
| Non-root container user | Limits blast radius if the app process is compromised. |
| Separate GKE node SA and CI/CD SA | Least privilege — node SA cannot push images; CI/CD SA cannot modify IAM or cluster config. |
| GCS remote state | Terraform state is shared and locked; no local state files to lose or conflict. |

---

## GitHub Secrets reference

| Secret | How to get the value | Used in |
|---|---|---|
| `GCP_PROJECT_ID` | your GCP project ID | `get-gke-credentials` |
| `WIF_PROVIDER` | `terraform output -raw cicd_wif_provider` | `google-github-actions/auth` |
| `WIF_SERVICE_ACCOUNT` | `terraform output -raw cicd_wif_service_account` | `google-github-actions/auth` |
| `AR_REGISTRY` | `terraform output -raw cicd_registry_url` | `env.IMAGE`, `configure-docker` |
| `GKE_CLUSTER_NAME` | your `cluster_name` tfvar | `get-gke-credentials` |
| `GKE_CLUSTER_ZONE` | your `region` tfvar | `get-gke-credentials` |

---

## Cost considerations (dev environment)

| Resource | Approximate monthly cost |
|---|---|
| GKE regional cluster (control plane) | ~$72 (GKE Standard) |
| 3× e2-medium nodes (1 per zone, 80 GB pd-standard) | ~$60 nodes + ~$10 disk |
| Global HTTP Load Balancer | ~$18 + $0.008/GB traffic |
| Artifact Registry storage | ~$0.10/GB/month |
| GCS (Terraform state + log export) | ~$0.02/GB |
| GCE e2-medium VM | ~$25 |

Tear down with `terraform destroy` in `environments/dev/` when not in use.
