# Architecture & Workflow — GKE Learning Projects

This document covers the complete picture of how both projects work together: from a developer pushing code to the app serving traffic on the internet.

---

## The two projects

| Project | Role |
|---|---|
| [Terraform-learning/](Terraform-learning/) | Provisions all GCP infrastructure using Terraform |
| [gke-sample-app/](gke-sample-app/) | The application — containerised, deployed to GKE via CI/CD |

Neither project works in isolation. Terraform creates the platform; the app runs on it.

---

## Full system diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Developer workstation                                                       │
│                                                                              │
│  ┌──────────────────────┐        ┌──────────────────────────────────────┐   │
│  │  Terraform-learning/ │        │  gke-sample-app/                     │   │
│  │  terraform apply     │        │  git push origin main                │   │
│  └──────────┬───────────┘        └──────────────────┬───────────────────┘   │
└─────────────┼────────────────────────────────────────┼─────────────────────┘
              │ provisions                             │ triggers
              ▼                                        ▼
┌─────────────────────────────┐    ┌──────────────────────────────────────────┐
│  GCP (Infrastructure)        │    │  GitHub Actions (CI/CD)                  │
│                              │    │                                           │
│  VPC + Subnet                │    │  Job 1: test                             │
│  GKE Cluster (3 zones)       │    │    pytest tests/ -v                      │
│  Global HTTP Load Balancer   │◄───│                                           │
│  GCR (image registry)        │    │  Job 2: build                            │
│  Workload Identity (WIF)     │◄───│    WIF auth → docker build → gcr push   │
│  CI/CD service account       │    │                                           │
│  Cloud Logging → GCS         │    │  Job 3: deploy                           │
│                              │◄───│    WIF auth → kubectl set image          │
└─────────────────────────────┘    └──────────────────────────────────────────┘
              │
              │  traffic
              ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Internet user  ──►  Global LB (anycast IP)  ──►  GKE NodePort 30080       │
│                                                   ──►  Calculator Pod :8080  │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Infrastructure layer (Terraform-learning)

Terraform provisions all GCP resources declaratively. Running `terraform apply` in `environments/dev/` creates every resource below.

### Network

```
VPC: my-custom-vpc
└── Subnet: my-subnet  (10.10.0.0/24)
    ├── Secondary range: gke-pods      (10.20.0.0/16)  ← pod IPs
    └── Secondary range: gke-services  (10.30.0.0/20)  ← ClusterIP IPs

Firewall rules:
  allow-http-ssh          — port 80 (all), port 22 (allowed CIDRs) → VMs
  allow-gke-control-plane — ports 443, 10250 → GKE nodes
  allow-lb-health-check   — GCP health-checker IPs → port 30080
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

Node pool: dev-gke-cluster-node-pool
  ├── Machine: e2-medium (2 vCPU, 4 GB)
  ├── Disk: 50 GB pd-balanced
  ├── Autoscaling: 1–3 nodes per zone (3–9 nodes total)
  ├── Auto-repair + auto-upgrade
  └── Shielded nodes (secure boot, integrity monitoring)
```

The cluster is regional — if one zone loses nodes, the other two keep serving traffic. This is the key HA property.

### Load balancer

```
Global HTTP Load Balancer
├── Static anycast external IP  ← point your DNS A record here
├── Forwarding rule: port 80 → HTTP proxy
├── URL map: all paths → backend service
├── Backend service
│   ├── Health check: GET /healthz on port 30080 (10s interval)
│   └── Backends (one per zone):
│       ├── us-central1-a instance group (GKE managed)
│       ├── us-central1-b instance group
│       └── us-central1-c instance group
└── Named port "http" = 30080 registered on each instance group
```

Why a Global LB instead of a per-service LoadBalancer? One Global LB handles all zones and uses GCP's anycast network (routes each user to the nearest GCP PoP). Per-service LoadBalancers provision a separate regional LB per Kubernetes Service — more expensive and more limited.

### IAM design

Two service accounts, each with minimum permissions:

```
gke-node-sa-dev@<project>.iam.gserviceaccount.com  (GKE node SA)
├── roles/logging.logWriter          — write pod logs to Cloud Logging
├── roles/monitoring.metricWriter    — write node/pod metrics
├── roles/monitoring.viewer          — read monitoring data
└── roles/artifactregistry.reader    — pull images from Artifact Registry

github-actions-cicd@<project>.iam.gserviceaccount.com  (CI/CD SA)
├── roles/storage.admin              — push/pull Docker images from GCR
└── roles/container.developer        — kubectl deploy to GKE
```

### Workload Identity Federation (CI/CD auth)

This is how GitHub Actions authenticates to GCP with no stored credentials.

```
Workload Identity Pool: github-pool
└── Provider: github-provider
    ├── Issuer: https://token.actions.githubusercontent.com
    ├── Attribute mapping:
    │   google.subject       ← assertion.sub       (workflow run identity)
    │   attribute.repository ← assertion.repository (e.g. "user/gke-sample-app")
    │   attribute.actor      ← assertion.actor      (GitHub username)
    │   attribute.ref        ← assertion.ref        (branch/tag ref)
    └── Attribute condition:
        assertion.repository == "your-username/gke-sample-app"
        (only this exact repo — forks and other repos are rejected)

IAM binding on the CI/CD SA:
  principalSet://iam.googleapis.com/.../attribute.repository/user/gke-sample-app
  → roles/iam.workloadIdentityUser
```

Token exchange flow at runtime:
1. GitHub runner requests a signed JWT from GitHub (no setup needed — automatic)
2. `google-github-actions/auth` sends JWT to GCP Security Token Service
3. STS verifies JWT signature + checks `attribute_condition`
4. STS returns a short-lived federated token
5. IAM exchanges it for an SA access token (scoped to `github-actions-cicd`)
6. Token is used for the job duration, then expires — nothing persists

### GCR registry

```
Registry: gcr.io/<project-id>
└── Repository: gcr.io/<project-id>/calculator
    ├── :sha-a1b2c3d  ← every push (immutable, traceable to a commit)
    ├── :sha-e4f5g6h
    └── :latest       ← points to the most recent push (mutable)
```

GCR is backed by a GCS bucket (`artifacts.<project-id>.appspot.com`). The `storage.admin` role on the CI/CD SA grants write access to this bucket.

---

## Application layer (gke-sample-app)

A simple Python Flask calculator, containerised and deployed to Kubernetes.

### Application

```
Flask app  (app/app.py)
├── GET  /          → serves the calculator HTML form
├── POST /calculate → performs arithmetic, returns result
└── GET  /healthz   → returns "ok" (used by K8s liveness/readiness probes)

WSGI server: gunicorn (2 workers)
Container port: 8080
```

### Docker image

```
Base: python:3.12-slim
├── COPY requirements.txt → pip install (cached layer — only re-runs when deps change)
├── COPY app/ .
├── USER appuser (non-root — security best practice)
└── CMD gunicorn --workers 2 --bind 0.0.0.0:8080 app:app
```

Layer ordering matters: dependencies are copied and installed before source code so Docker reuses the `pip install` layer on code-only changes (much faster rebuilds).

### Kubernetes resources

```
Deployment: calculator
├── Replicas: 2
├── Strategy: RollingUpdate (maxSurge=1, maxUnavailable=0)
│   → always keeps 2 healthy pods; briefly runs 3 during an update
├── Container: gcr.io/<project>/calculator:<sha-tag>
│   ├── Resources: 100m–250m CPU, 128–256 MB RAM
│   ├── Liveness probe:  GET /healthz every 15s  → restart if failing
│   └── Readiness probe: GET /healthz every 10s  → remove from LB if failing
└── ImagePullPolicy: Always  (never use a stale cached image)

Service: calculator
├── Type: NodePort
├── port 80  → targetPort 8080  → nodePort 30080
└── selector: app=calculator
```

The Deployment's `node_locations` are pinned in the GKE module (`us-central1-a/b/c`) so Terraform can use zone names as static `for_each` keys when registering instance groups as LB backends.

---

## CI/CD pipeline

Every `git push` to `main` triggers a three-job pipeline.

### Job 1 — test

Runs on every push and every pull request. Fails the pipeline before any image is built.

```
ubuntu-latest runner
└── pip install Flask gunicorn pytest
└── pytest tests/ -v
    ├── test_home_page_loads
    ├── test_health_check
    ├── test_addition / subtraction / multiplication / division
    ├── test_division_by_zero
    ├── test_invalid_input
    ├── test_negative_numbers
    └── test_decimal_numbers
```

### Job 2 — build (push to main only)

Builds and pushes the Docker image to GCR. Only runs after `test` passes.

```
ubuntu-latest runner
├── Authenticate to GCP via WIF (id-token: write permission required)
├── gcloud auth configure-docker  → registers gcloud as Docker credential helper
├── docker build
│   ├── Tags: gcr.io/<project>/calculator:sha-<abc>  (immutable)
│   │         gcr.io/<project>/calculator:latest     (mutable)
│   └── Cache: type=gha (GitHub Actions cache — reuses unchanged layers)
└── docker push both tags
```

The SHA tag is computed as `sha-$(git rev-parse --short HEAD)` — 7 hex characters uniquely identifying the commit.

### Job 3 — deploy (push to main only)

Deploys the new image to GKE. Only runs after `build` passes.

```
ubuntu-latest runner
├── Authenticate to GCP via WIF  (fresh — each job starts clean)
├── gcloud container clusters get-credentials  → writes kubeconfig
├── kubectl apply -f k8s/        → creates/updates Deployment and Service
├── kubectl set image deployment/calculator \
│     calculator=gcr.io/<project>/calculator:sha-<abc>
│   → triggers a rolling update using the SHA from the build job output
└── kubectl rollout status --timeout=120s
    → waits for all pods to become healthy
    → fails the job (and marks deploy as failed) if pods don't become healthy
```

### Rolling update behaviour

```
Before update:  [Pod v1]  [Pod v1]
                          ↓ kubectl set image
During update:  [Pod v1]  [Pod v1]  [Pod v2]   ← maxSurge=1 allows temporary extra pod
                          ↓ Pod v2 passes readiness probe
                [Pod v1]  [Pod v2]              ← Pod v1 is terminated
                          ↓
After update:   [Pod v2]  [Pod v2]
```

`maxUnavailable=0` ensures there are always 2 healthy pods serving traffic throughout the update. Zero downtime.

---

## End-to-end request flow

```
Browser: GET http://<load-balancer-ip>/

1. DNS resolves to the static anycast IP (provisioned by Terraform)

2. GCP Global LB receives the request at the nearest PoP
   - Checks backend health (pods must pass /healthz readiness probe)
   - Selects a backend: us-central1-a, b, or c instance group

3. Request hits a GKE node on NodePort 30080
   - kube-proxy intercepts and forwards to one of the calculator Pods

4. gunicorn in the Pod handles the HTTP request
   - Flask routes GET / to the index() function
   - render_template returns the calculator HTML page

5. Browser renders the page, user fills the form, submits

6. Browser: POST http://<load-balancer-ip>/calculate
   - Same path: LB → node → kube-proxy → Pod
   - Flask routes POST /calculate to the calculate() function
   - Returns HTML with the result
```

---

## Sequence: developer ships a new feature

```
Developer
  │
  ├─ writes code, runs: pytest tests/ -v  (locally)
  │
  ├─ git push origin main
  │
  │              GitHub Actions
  │              │
  │              ├─ [test]   pytest — 10 tests pass
  │              │
  │              ├─ [build]
  │              │   ├─ WIF: GitHub JWT → GCP STS → SA access token
  │              │   ├─ docker build (layers cached — fast)
  │              │   └─ docker push gcr.io/<project>/calculator:sha-abc1234
  │              │
  │              └─ [deploy]
  │                  ├─ WIF auth (fresh credentials)
  │                  ├─ kubectl apply -f k8s/  (no-op if manifests unchanged)
  │                  ├─ kubectl set image → rolling update begins
  │                  └─ kubectl rollout status → waits for healthy pods
  │
  ▼
GKE: new pods serving the updated code
LB: traffic shifts to new pods automatically (readiness probes gate this)

Total time: ~3–5 minutes from push to live
```

---

## Key design decisions

| Decision | Reason |
|---|---|
| Workload Identity Federation over SA keys | No credentials to leak, rotate, or audit. Keys are banned by org policy. |
| Regional GKE cluster | Control plane survives single-zone failures. |
| `node_locations` pinned explicitly | Terraform `for_each` requires static map keys — zone names known at plan time. |
| Global HTTP LB over per-service LoadBalancer | One LB for all zones; anycast routing; cheaper than one LB per Service. |
| SHA image tags over `latest` | Every deployment is traceable to an exact commit. Rollbacks are precise. |
| `maxUnavailable=0` rolling update | Zero downtime — always `replicas` healthy pods during an update. |
| Non-root container user | Limits blast radius if the app process is compromised. |
| Separate GKE node SA and CI/CD SA | Least privilege — node SA cannot push images; CI/CD SA cannot modify IAM. |
| GCS remote state | Terraform state is shared and locked; no local state files to lose. |

---

## Environment variables / GitHub Secrets reference

| Secret | Source | Used in |
|---|---|---|
| `GCP_PROJECT_ID` | your GCP project | `env.IMAGE`, `get-gke-credentials` |
| `WIF_PROVIDER` | `terraform output -raw cicd_wif_provider` | `google-github-actions/auth` |
| `WIF_SERVICE_ACCOUNT` | `terraform output -raw cicd_wif_service_account` | `google-github-actions/auth` |
| `GKE_CLUSTER_NAME` | your `cluster_name` tfvar | `get-gke-credentials` |
| `GKE_CLUSTER_ZONE` | your `region` tfvar | `get-gke-credentials` |

---

## Cost considerations (dev environment)

| Resource | Approximate monthly cost |
|---|---|
| GKE regional cluster (control plane) | ~$72 (GKE standard) |
| 3× e2-medium nodes (1 per zone) | ~$60 |
| Global HTTP Load Balancer | ~$18 + $0.008/GB |
| GCR storage | ~$0.026/GB |
| GCS (state + logs) | ~$0.02/GB |
| GCE e2-medium VM | ~$25 |

Tear down with `terraform destroy` in `environments/dev/` when not in use.
