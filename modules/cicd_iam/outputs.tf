# ============================================================
# modules/cicd_iam/outputs.tf
# ============================================================
# These outputs are the values you copy into GitHub Secrets.
# After `terraform apply`, run:
#   terraform output -raw wif_provider
#   terraform output -raw wif_service_account
# and paste each value into the corresponding GitHub Secret.

output "wif_provider" {
  description = <<-EOT
    Full resource name of the Workload Identity Provider.
    Copy this value into the GitHub Secret: WIF_PROVIDER
    Used by google-github-actions/auth in the CI/CD workflow.
  EOT
  value = google_iam_workload_identity_pool_provider.github.name
}

output "wif_service_account" {
  description = <<-EOT
    Email of the GitHub Actions service account to impersonate.
    Copy this value into the GitHub Secret: WIF_SERVICE_ACCOUNT
    Used by google-github-actions/auth in the CI/CD workflow.
  EOT
  value = google_service_account.cicd.email
}

output "gcr_registry_url" {
  description = <<-EOT
    Base URL for pushing images to GCR.
    Full image path: <gcr_registry_url>/<image-name>:<tag>
    Update the IMAGE env var in .github/workflows/ci-cd.yml with this.
  EOT
  value = "gcr.io/${var.project_id}"
}

output "cicd_sa_name" {
  description = "Full resource name of the CI/CD service account (for IAM references)."
  value       = google_service_account.cicd.name
}
