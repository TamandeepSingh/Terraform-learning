# ============================================================
# modules/gce/variables.tf
# ============================================================

variable "vm_name" {
  description = "Name of the Compute Engine VM instance."
  type        = string
}

variable "machine_type" {
  description = "GCP machine type. e2-micro is free-tier eligible."
  type        = string
}

variable "zone" {
  description = "GCP zone where the VM will be created (e.g. us-central1-a)."
  type        = string
}

variable "vm_tags" {
  description = "Network tags applied to the VM. Must match target_tags in firewall rules."
  type        = list(string)
}

variable "vm_image" {
  description = "Boot disk image. Format: <project>/<family> or full self-link."
  type        = string
  # e.g. "debian-cloud/debian-12"
}

variable "disk_size_gb" {
  description = "Boot disk size in GB."
  type        = number
}

# Passed in from vpc module outputs — keeps this module decoupled from networking.
variable "vpc_id" {
  description = "VPC self-link. Use module.vpc.vpc_id from the environment."
  type        = string
}

variable "subnet_id" {
  description = "Subnet self-link. Use module.vpc.subnet_id from the environment."
  type        = string
}

variable "environment" {
  description = "Environment label (dev / staging / prod)."
  type        = string
  default     = "dev"
}
