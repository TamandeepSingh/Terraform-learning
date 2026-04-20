# ============================================================
# modules/cicd_iam/outputs.tf
# ============================================================
# After `terraform apply`, get GitHub Secret values with:
#   terraform output -raw cicd_wif_provider
#   terraform output -raw cicd_wif_service_account
#
# Get the image base URL for ci-cd.yml with:
#   terraform output -raw cicd_registry_url

output "wif_provider" {
  description = "Paste into GitHub Secret: WIF_PROVIDER"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "wif_service_account" {
  description = "Paste into GitHub Secret: WIF_SERVICE_ACCOUNT"
  value       = google_service_account.cicd.email
}

output "registry_url" {
  description = <<-EOT
    Base URL for pushing images to Artifact Registry.
    Full image path: <registry_url>/<image-name>:<tag>
    Update IMAGE in .github/workflows/ci-cd.yml to: <registry_url>/calculator
    Also update gcloud auth configure-docker to use this hostname.
  EOT
  value = "${var.ar_location}-docker.pkg.dev/${var.project_id}/${var.ar_repo_id}"
}

output "ar_hostname" {
  description = "Artifact Registry hostname — pass to 'gcloud auth configure-docker' in CI/CD."
  value       = "${var.ar_location}-docker.pkg.dev"
}

output "cicd_sa_name" {
  description = "Full resource name of the CI/CD service account."
  value       = google_service_account.cicd.name
}
