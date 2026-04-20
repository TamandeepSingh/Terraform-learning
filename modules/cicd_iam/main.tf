# ============================================================
# modules/cicd_iam/main.tf
# ============================================================
# Sets up everything GitHub Actions needs to push images and deploy
# to GKE — without any stored credentials (no SA key files).
#
# Resources created:
#   1. GCP APIs enabled (Artifact Registry, WIF prerequisites)
#   2. Artifact Registry Docker repository  ← repo name set via var.ar_repo_id
#   3. GitHub Actions service account
#   4. IAM: artifactregistry.writer scoped to the specific repo (not project-wide)
#   5. IAM: container.developer for GKE deployments
#   6. Workload Identity Pool  — the trust boundary for external identities
#   7. Workload Identity Provider — GitHub OIDC issuer config + attribute mapping
#   8. IAM binding — allows only your GitHub repo to impersonate the SA
#
# GCR vs Artifact Registry:
#
#   GCR (deprecated, do not use):
#     - google_container_registry resource is broken (provider bug)
#     - No named repos — one bucket per project
#     - Requires roles/storage.admin (project-wide GCS access)
#     - Image URL: gcr.io/PROJECT/image:tag
#
#   Artifact Registry (current):
#     - google_artifact_registry_repository — explicit named repo
#     - Repo name set in var.ar_repo_id (e.g. "calculator-repo")
#     - Requires roles/artifactregistry.writer scoped to that repo only
#     - Image URL: REGION-docker.pkg.dev/PROJECT/REPO_ID/image:tag
#     - Supports cleanup policies, multi-format, per-repo IAM
#
# How Workload Identity Federation works:
#
#   GitHub Actions runner
#     │  1. Requests a signed OIDC token from GitHub
#     │     Claims: repository, actor, ref, sha, workflow, ...
#     ▼
#   GCP Security Token Service (STS)
#     │  2. Verifies JWT signature against GitHub's public JWKS
#     │  3. Evaluates attribute_condition — must be YOUR repo exactly
#     │  4. Returns a federated identity token
#     ▼
#   GCP IAM
#     │  5. Exchanges federated token → short-lived SA access token
#     ▼
#   Token expires when the job ends. No key. Nothing to rotate.

# ---------------------------------------------------------------
# Enable required GCP APIs
# ---------------------------------------------------------------

# Artifact Registry API — must be enabled before creating any repository.
resource "google_project_service" "artifact_registry" {
  project            = var.project_id
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

# IAM Credentials API — used by WIF to exchange a federated token
# for a short-lived service account access token.
resource "google_project_service" "iam_credentials" {
  project            = var.project_id
  service            = "iamcredentials.googleapis.com"
  disable_on_destroy = false
}

# Security Token Service API — the GCP endpoint GitHub's OIDC token
# is sent to in exchange for a federated identity token.
resource "google_project_service" "sts" {
  project            = var.project_id
  service            = "sts.googleapis.com"
  disable_on_destroy = false
}

# ---------------------------------------------------------------
# Artifact Registry — Docker repository
# ---------------------------------------------------------------
# This is where you name your container image repository.
# The name is set via var.ar_repo_id (e.g. "calculator-repo").
#
# Image URL format:
#   <ar_location>-docker.pkg.dev/<project_id>/<ar_repo_id>/<image>:<tag>
#
# Example with defaults:
#   us-central1-docker.pkg.dev/my-project/calculator-repo/calculator:sha-a1b2c3
#
# Why region matters: images are stored in the chosen GCP region.
# Use the same region as your GKE cluster for the fastest pulls.
resource "google_artifact_registry_repository" "app" {
  project       = var.project_id
  location      = var.ar_location    # should match your GKE cluster region
  repository_id = var.ar_repo_id     # ← THE REPO NAME — set in tfvars
  description   = "Docker images built and pushed by GitHub Actions CI/CD."
  format        = "DOCKER"

  depends_on = [google_project_service.artifact_registry]
}

# ---------------------------------------------------------------
# GitHub Actions service account
# ---------------------------------------------------------------
# Minimal SA — only the permissions the CI/CD pipeline actually needs.
resource "google_service_account" "cicd" {
  project      = var.project_id
  account_id   = var.sa_id
  display_name = "GitHub Actions CI/CD"
  description  = "Impersonated via WIF to push images to Artifact Registry and deploy to GKE."
}

# ---------------------------------------------------------------
# IAM: Artifact Registry writer — scoped to the specific repo
# ---------------------------------------------------------------
# roles/artifactregistry.writer on the repository resource (not project):
#   - docker push  — upload new images and tags
#   - docker pull  — download images (needed during multi-stage builds)
#   - list tags
#
# Scoping to the repository means this SA cannot touch any other
# AR repo, GCS bucket, or service in the project.
resource "google_artifact_registry_repository_iam_member" "cicd_writer" {
  project    = var.project_id
  location   = google_artifact_registry_repository.app.location
  repository = google_artifact_registry_repository.app.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.cicd.email}"
}

# ---------------------------------------------------------------
# IAM: GKE developer — project-level
# ---------------------------------------------------------------
# roles/container.developer allows kubectl apply, set image, rollout.
# Does NOT allow creating or deleting GKE clusters.
resource "google_project_iam_member" "cicd_gke_developer" {
  project = var.project_id
  role    = "roles/container.developer"
  member  = "serviceAccount:${google_service_account.cicd.email}"
}

# ---------------------------------------------------------------
# Workload Identity Pool
# ---------------------------------------------------------------
# A named trust boundary for external identity providers.
# Any provider added to this pool can potentially authenticate to GCP.
# The actual access is controlled by IAM bindings on specific resources.
resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions Pool"
  description               = "Trusts GitHub's OIDC token issuer for keyless CI/CD auth."

  depends_on = [google_project_service.sts]
}

# ---------------------------------------------------------------
# Workload Identity Provider (GitHub OIDC)
# ---------------------------------------------------------------
# Configures how GitHub's JWT tokens are validated and translated
# into GCP identity attributes.
#
# GitHub OIDC token claims:
#   sub        = "repo:<owner>/<repo>:ref:refs/heads/main"
#   repository = "<owner>/<repo>"     e.g. "tsinghkhamba/gke-sample-app"
#   actor      = GitHub username
#   ref        = git ref              e.g. "refs/heads/main"
#   sha        = commit SHA
resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub OIDC"
  description                        = "Validates GitHub Actions OIDC tokens. Restricted to: ${var.github_repo}"

  # Translate GitHub JWT claims → GCP attributes used in IAM conditions.
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # MUST be true for the token to be accepted.
  # Rejects any token that isn't from your specific repo —
  # forks, other repos, and unrelated workflows are all denied here.
  attribute_condition = "assertion.repository == '${var.github_repo}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# ---------------------------------------------------------------
# Allow GitHub Actions to impersonate the CI/CD SA
# ---------------------------------------------------------------
# principalSet:// selects all identities in the pool where
# attribute.repository matches var.github_repo.
# This is the final gate: the token passed the provider's
# attribute_condition, and now IAM grants it SA impersonation.
resource "google_service_account_iam_member" "github_wif_binding" {
  service_account_id = google_service_account.cicd.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}
