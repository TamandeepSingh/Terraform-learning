# ============================================================
# modules/gce/outputs.tf
# ============================================================

output "vm_internal_ip" {
  description = "Private IP of the VM — only reachable within the VPC."
  value       = google_compute_instance.web_server.network_interface[0].network_ip
}

output "vm_external_ip" {
  description = "Ephemeral public IP. Visit http://<ip>/ to see the Apache page."
  value       = google_compute_instance.web_server.network_interface[0].access_config[0].nat_ip
}

output "ssh_command" {
  description = "Run this to SSH into the VM after apply."
  value       = "gcloud compute ssh ${google_compute_instance.web_server.name} --zone=${var.zone}"
}
