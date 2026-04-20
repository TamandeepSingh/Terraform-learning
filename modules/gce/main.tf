# ============================================================
# modules/gce/main.tf — Compute Engine VM instance
# ============================================================
# This module provisions a single VM and attaches it to the
# VPC / subnet created by the vpc module. It installs Apache
# on first boot via a startup script.
#
# Inputs vpc_id and subnet_id come directly from the vpc module's
# outputs, so there's no hard-coded network name here.

# locals{} defines computed, reusable values scoped to this module.
# Separating the startup script here keeps the resource block clean.
locals {
  startup_script = <<-SCRIPT
    #!/bin/bash
    set -euo pipefail          # exit on error, unset variable, or pipe failure

    apt-get update -y
    apt-get install -y apache2

    # Start Apache now and ensure it restarts on reboot.
    systemctl enable apache2
    systemctl start apache2

    # Write a simple page — visit http://<external-ip>/ to see it.
    cat <<HTML > /var/www/html/index.html
    <!DOCTYPE html>
    <html>
      <head><title>GCP VM — Terraform</title></head>
      <body>
        <h1>Hello from $(hostname)!</h1>
        <p>Deployed by Terraform on GCP — environment: ${var.environment}</p>
      </body>
    </html>
    HTML
  SCRIPT
}

# google_compute_instance is one VM in one zone.
# For high-availability use a Managed Instance Group (MIG) instead.
resource "google_compute_instance" "web_server" {
  name         = var.vm_name
  machine_type = var.machine_type # e.g. e2-micro (free tier)
  zone         = var.zone         # e.g. us-central1-a

  # Network tags connect this VM to firewall rules that share the same tag.
  # The vpc module's allow_http_ssh rule targets these tags.
  tags = var.vm_tags

  boot_disk {
    initialize_params {
      # Using a *family* (e.g. debian-cloud/debian-12) always resolves to the
      # latest image in that family — you get automatic OS patch currency.
      image = var.vm_image
      size  = var.disk_size_gb
      type  = "pd-balanced" # pd-standard (HDD) | pd-balanced | pd-ssd
    }
  }

  network_interface {
    # These IDs come from the vpc module outputs, passed in by the environment.
    network    = var.vpc_id
    subnetwork = var.subnet_id

    # An empty access_config block assigns an ephemeral external IP.
    # Remove this block entirely for a private-only VM (use Cloud IAP
    # or a bastion host to SSH in that case).
    access_config {}
  }

  # metadata_startup_script runs as root on the very first boot.
  # GCP injects it via the metadata server; the guest agent executes it.
  metadata_startup_script = local.startup_script

  # Required when changing attributes that need the VM to stop
  # (e.g. machine_type). Without this, Terraform would return an error.
  allow_stopping_for_update = true

  labels = {
    environment = var.environment
    managed_by  = "terraform"
  }
}
