# ============================================================
# modules/load_balancer/outputs.tf
# ============================================================

output "lb_ip" {
  description = "Static external IP of the load balancer. Point your DNS A record here."
  value       = google_compute_global_address.lb_ip.address
}

output "lb_url" {
  description = "Full URL to test the load balancer from a browser or curl."
  value       = "http://${google_compute_global_address.lb_ip.address}"
}

output "backend_service_name" {
  description = "Name of the backend service. Useful for kubectl and GCP console lookups."
  value       = google_compute_backend_service.default.name
}
