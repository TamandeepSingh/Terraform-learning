# ============================================================
# modules/cicd_iam/main.tf
# ============================================================
# This module sets up everything GitHub Actions needs to deploy
# to GKE and push images to GCR — without storing any long-lived
# credentials (no SA key files).
#
# Resources created:
#   1. GCP APIs enabled (Container Registry, WIF prerequisites)
#   2. GCR repository (auto-created by the containerregistry API)
#   3. GitHub Actions service account
#   4. IAM roles on that SA (GCR push, GKE deploy)
#   5. Workload Identity Pool  — the trust boundary for GitHub
#   6. Workload Identity Provider — trusts GitHub's OIDC token issuer
#   7. IAM binding — allows GitHub Actions (specific repo) to impersonate the SA
#
# How Workload Identity Federation works:
#
#   GitHub Actions runner
#     │
#     │  1. Requests a short-lived OIDC token from GitHub
#     │     (contains claims: repository, actor, branch, sha, etc.)
#     │
#     ▼
#   GCP Security Token Service (STS)
#     │  2. Verifies the token is signed by GitHub's OIDC issuer
#     │  3. Checks attribute_condition (must be YOUR repo)
#     │  4. Returns a federated identity token
#     │
#     ▼
#   GCP IAM  5. Exchanges federated token for a short-lived
#               service account access token (token impersonation)
#     │
#     ▼
#   GitHub Actions runner now has a valid GCP access token
#   scoped to the cicd service account — no JSON key involved.

# ---------------------------------------------------------------
# Enable required GCP APIs
# ---------------------------------------------------------------
# Terraform can enable APIs for you. Without these, resource creation fails.
# disable_on_destroy = false means Terraform won't disable the API when
# you run `terraform destroy` — other resources may still need it.

# Container Registry API — allows pushing and pulling Docker images via gcr.io.
# GCR stores images in a GCS bucket that GCP manages automatically.
resource "google_project_service" "container_registry" {
  project            = var.project_id
  service            = "containerregistry.googleapis.com"
  disable_on_destroy = false
}

# IAM Credentials API — required for service account token impersonation.
# WIF uses this to exchange a federated identity token for an SA access token.
resource "google_project_service" "iam_credentials" {
  project            = var.project_id
  service            = "iamcredentials.googleapis.com"
  disable_on_destroy = false
}

# Security Token Service API — required for WIF token exchange.
# GCP STS is the endpoint that accepts GitHub's OIDC token.
resource "google_project_service" "sts" {
  project            = var.project_id
  service            = "sts.googleapis.com"
  disable_on_destroy = false
}

# ---------------------------------------------------------------
# GCR repository
# ---------------------------------------------------------------
# google_container_registry ensures the GCR registry is initialised
# for this project and optionally pins it to a GCS multi-region location.
#
# GCR doesn't have a concept of "named repos" like Artifact Registry does.
# The repo is automatically created when you first push an image.
# The image path format is: gcr.io/<project-id>/<image-name>:<tag>
#
# Note: Google is migrating GCR to Artifact Registry. For new projects
# consider using google_artifact_registry_repository instead, which
# supports more features (cleanup policies, format-specific settings).
resource "google_container_registry" "registry" {
  project  = var.project_id
  location = var.gcr_location   # US, EU, or ASIA (maps to us., eu., asia. prefixes)

  depends_on = [google_project_service.container_registry]
}

# ---------------------------------------------------------------
# GitHub Actions service account
# ---------------------------------------------------------------
# A dedicated SA for CI/CD with only the permissions it needs.
# Principle of least privilege: this SA cannot modify IAM, create VMs, etc.
resource "google_service_account" "cicd" {
  project      = var.project_id
  account_id   = var.sa_id
  display_name = "GitHub Actions CI/CD"
  description  = "Impersonated by GitHub Actions via WIF to push images to GCR and deploy to GKE."
}

# ---------------------------------------------------------------
# IAM roles for the CI/CD service account
# ---------------------------------------------------------------

# roles/storage.admin — GCR images are stored in a GCS bucket
# (named artifacts.<project-id>.appspot.com). This SA needs storage
# write access to push images to that bucket.
# storage.admin is broader than needed but is the conventional role for GCR.
# For tighter scoping, use storage.objectAdmin on the specific GCR bucket.
resource "google_project_iam_member" "cicd_storage_admin" {
  project = var.project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${google_service_account.cicd.email}"
}

# roles/container.developer — allows:
#   - kubectl apply (create/update Deployments, Services, etc.)
#   - kubectl set image (trigger rolling updates)
#   - kubectl rollout status (wait for rollout)
# Does NOT allow creating or deleting GKE clusters.
resource "google_project_iam_member" "cicd_gke_developer" {
  project = var.project_id
  role    = "roles/container.developer"
  member  = "serviceAccount:${google_service_account.cicd.email}"
}

# ---------------------------------------------------------------
# Workload Identity Pool
# ---------------------------------------------------------------
# A pool is a container for external identity providers.
# Think of it as a trust boundary: "identities from these providers
# are allowed to access GCP resources."
# One pool per environment (or one shared pool) is typical.
resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions Pool"
  description               = "Trusts GitHub's OIDC token issuer for CI/CD authentication."

  depends_on = [google_project_service.sts]
}

# ---------------------------------------------------------------
# Workload Identity Provider (GitHub OIDC)
# ---------------------------------------------------------------
# A provider defines HOW external tokens are validated and HOW
# claims in the token map to GCP attributes.
#
# GitHub's OIDC token contains these claims (among others):
#   sub         = "repo:<owner>/<repo>:ref:refs/heads/main"
#   repository  = "<owner>/<repo>"
#   actor       = "<github-username>"
#   workflow    = "<workflow-name>"
#
# attribute_mapping translates GitHub claims → GCP attributes.
# GCP attributes can then be used in attribute_condition to restrict access.
resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub OIDC"
  description                        = "Validates OIDC tokens issued by GitHub Actions."

  # Map GitHub JWT claims to GCP attributes.
  # Left side  = GCP attribute name (used in conditions and IAM bindings)
  # Right side = expression evaluated against the JWT token (CEL syntax)
  attribute_mapping = {
    "google.subject"       = "assertion.sub"         # unique identity string per workflow run
    "attribute.actor"      = "assertion.actor"       # GitHub username that triggered the run
    "attribute.repository" = "assertion.repository"  # e.g. "tsinghkhamba/gke-sample-app"
    "attribute.ref"        = "assertion.ref"         # e.g. "refs/heads/main"
  }

  # attribute_condition is a CEL expression that MUST be true for the
  # token to be accepted. This restricts authentication to a specific repo,
  # preventing any fork or unrelated repo from impersonating this SA.
  # Format: "owner/repo-name"
  attribute_condition = "assertion.repository == '${var.github_repo}'"

  oidc {
    # GitHub's OIDC discovery URL. GCP fetches the public keys from here
    # to verify the JWT signature on every authentication attempt.
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# ---------------------------------------------------------------
# Allow GitHub Actions to impersonate the CI/CD SA
# ---------------------------------------------------------------
# This IAM binding on the SA grants the "workloadIdentityUser" role
# to any identity from the WIF pool whose attribute.repository matches
# the github_repo variable.
#
# principalSet:// selects a GROUP of identities sharing an attribute.
# (As opposed to principal:// which selects a single identity by subject.)
# Using principalSet with attribute.repository means: "any token from
# the github-pool where repository == var.github_repo".
resource "google_service_account_iam_member" "github_wif_binding" {
  service_account_id = google_service_account.cicd.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}
