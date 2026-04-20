# ============================================================
# modules/cicd_iam/variables.tf
# ============================================================

variable "project_id" {
  description = "GCP project ID. All resources are created in this project."
  type        = string
}

variable "sa_id" {
  description = <<-EOT
    Account ID for the GitHub Actions service account.
    Must be 6–30 characters: lowercase letters, numbers, hyphens.
    Full email: <sa_id>@<project_id>.iam.gserviceaccount.com
  EOT
  type    = string
  default = "github-actions-cicd"
}

variable "github_repo" {
  description = <<-EOT
    GitHub repository in "owner/repo" format.
    Example: "tsinghkhamba/gke-sample-app"
    Only GitHub Actions runs from this exact repo can impersonate the SA.
    Forks and other repos are rejected by the WIF attribute_condition.
  EOT
  type = string
}

variable "ar_repo_id" {
  description = <<-EOT
    Name of the Artifact Registry Docker repository.
    This becomes part of the image URL:
      <ar_location>-docker.pkg.dev/<project_id>/<ar_repo_id>/<image>:<tag>
    Example: "calculator-repo" → us-central1-docker.pkg.dev/my-project/calculator-repo/calculator:sha-abc
    Use lowercase letters, numbers, and hyphens only.
  EOT
  type    = string
  default = "calculator-repo"
}

variable "ar_location" {
  description = <<-EOT
    GCP region for the Artifact Registry repository.
    Should match your GKE cluster region so image pulls are fast (no cross-region egress).
    Example: "us-central1"
    Unlike GCR (which used multi-region: US/EU/ASIA), Artifact Registry
    uses standard GCP regions for Docker repositories.
  EOT
  type    = string
  default = "us-central1"
}
