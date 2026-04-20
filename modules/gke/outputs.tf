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
    Self-link URLs of the node pool's zonal instance groups (not IGMs).
    A regional cluster produces one group per zone (typically 3).
    Pass this to the load_balancer module so it can register them as backends.
  EOT
  # google_container_node_pool.instance_group_urls returns Instance Group Manager
  # (IGM) self-links: .../instanceGroupManagers/gke-...
  # The load balancer backend service requires the Instance Group self-link:
  #   .../instanceGroups/gke-...
  # The URLs are identical except for the collection name — replace() fixes it.
  value = [
    for url in google_container_node_pool.primary_nodes.instance_group_urls :
    replace(url, "instanceGroupManagers", "instanceGroups")
  ]
}

output "instance_group_url_map" {
  description = <<-EOT
    Map of zone → instance group self-link URL (not IGM URL).
    Keys (zone names) are known at plan time; values resolved after apply.
    Use this with the load_balancer module — resource for_each requires static keys.
  EOT
  # Same IGM → IG URL conversion as instance_group_urls above.
  # The for expression iterates var.node_zones (known at plan time) so
  # Terraform can determine the map keys during terraform plan.
  value = {
    for i, zone in var.node_zones :
    zone => replace(
      google_container_node_pool.primary_nodes.instance_group_urls[i],
      "instanceGroupManagers",
      "instanceGroups"
    )
  }
}
