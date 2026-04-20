# ============================================================
# modules/gke/outputs.tf
# ============================================================

output "cluster_name" {
  description = "Name of the GKE cluster."
  value       = google_container_cluster.primary.name
}

output "cluster_endpoint" {
  description = "IP address of the Kubernetes API server."
  value       = google_container_cluster.primary.endpoint
  sensitive   = true # hide from terminal output; access via terraform output -raw
}

output "cluster_ca_certificate" {
  description = "Base64-encoded CA certificate for the cluster. Used to verify the API server."
  value       = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "get_credentials_command" {
  description = "Run this after apply to configure kubectl to talk to the cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --region=${var.region} --project=${var.project_id}"
}

output "instance_group_urls" {
  description = <<-EOT
    Self-link URLs of the node pool's zonal managed instance groups.
    A regional cluster produces one group per zone (typically 3).
    Pass this to the load_balancer module so it can register them as backends.
  EOT
  value = google_container_node_pool.primary_nodes.instance_group_urls
}

output "instance_group_url_map" {
  description = <<-EOT
    Map of zone → instance group self-link URL.
    Keys (zone names) are known at plan time; values are resolved after apply.
    Use this with the load_balancer module — resource for_each requires static keys.
    Built with a for expression (not zipmap) so Terraform can determine keys at plan time.
  EOT
  value = { for i, zone in var.node_zones : zone => google_container_node_pool.primary_nodes.instance_group_urls[i] }
}
