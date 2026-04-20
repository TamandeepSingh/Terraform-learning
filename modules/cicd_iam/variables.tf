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
    Must be 6–30 characters, lowercase letters, numbers, and hyphens.
    The full email will be: <sa_id>@<project_id>.iam.gserviceaccount.com
  EOT
  type        = string
  default     = "github-actions-cicd"
}

variable "github_repo" {
  description = <<-EOT
    GitHub repository in "owner/repo" format.
    Example: "tsinghkhamba/gke-sample-app"
    Only GitHub Actions runs from this exact repo can impersonate the SA.
    Forks and other repos are rejected by the attribute_condition.
  EOT
  type        = string
}

variable "gcr_location" {
  description = <<-EOT
    GCS multi-region location for the Container Registry bucket.
    Controls which gcr.io hostname images are stored under:
      US   → gcr.io   (default, global anycast)
      EU   → eu.gcr.io
      ASIA → asia.gcr.io
    Choose the region closest to your GKE cluster for faster pulls.
  EOT
  type    = string
  default = "US"

  validation {
    condition     = contains(["US", "EU", "ASIA"], var.gcr_location)
    error_message = "gcr_location must be US, EU, or ASIA."
  }
}
