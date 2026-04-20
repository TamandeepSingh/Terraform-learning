# ============================================================
# modules/iam/variables.tf
# ============================================================

variable "project_id" {
  description = "GCP project ID where the service account will be created."
  type        = string
}

variable "gke_node_sa_id" {
  description = <<-EOT
    account_id for the GKE node SA. Must be 6-30 chars, lowercase letters,
    digits, and hyphens. The full email becomes <id>@<project>.iam.gserviceaccount.com.
  EOT
  type        = string
  default     = "gke-node-sa"
}
