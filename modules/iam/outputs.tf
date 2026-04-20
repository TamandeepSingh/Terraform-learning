# ============================================================
# modules/iam/outputs.tf
# ============================================================

output "gke_node_sa_email" {
  description = "Email of the GKE node SA. Pass this to the gke module's node_service_account variable."
  value       = google_service_account.gke_node_sa.email
}
