# ============================================================
# modules/vpc/outputs.tf
# ============================================================
# These values are exported so other modules (gce, gke) can
# attach their resources to the correct VPC / subnet without
# hard-coding names or IDs.

output "vpc_id" {
  description = "Self-link of the VPC network. Used where a full resource URL is needed."
  value       = google_compute_network.vpc.id
}

output "vpc_name" {
  description = "Short name of the VPC. Used by GKE cluster's 'network' field."
  value       = google_compute_network.vpc.name
}

output "subnet_id" {
  description = "Self-link of the subnet. Used by GCE VMs in their network_interface block."
  value       = google_compute_subnetwork.subnet.id
}

output "subnet_name" {
  description = "Short name of the subnet. Used by GKE cluster's 'subnetwork' field."
  value       = google_compute_subnetwork.subnet.name
}

# GKE ip_allocation_policy references these range names — passing them
# as outputs keeps the gke module decoupled from the vpc module's internals.
output "pods_range_name" {
  description = "Name of the secondary range for GKE pods. Pass to the gke module."
  value       = var.pods_range_name
}

output "services_range_name" {
  description = "Name of the secondary range for GKE services. Pass to the gke module."
  value       = var.services_range_name
}
