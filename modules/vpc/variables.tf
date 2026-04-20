# ============================================================
# modules/vpc/variables.tf
# ============================================================
# Variables are the module's public interface — callers must
# supply values for those without a default.

variable "vpc_name" {
  description = "Name of the VPC network."
  type        = string
}

variable "subnet_name" {
  description = "Name of the regional subnet."
  type        = string
}

variable "subnet_cidr" {
  description = "Primary IP range for the subnet. VMs and GKE nodes get IPs here."
  type        = string
  # e.g. "10.10.0.0/24"
}

variable "region" {
  description = "GCP region where the subnet will be created."
  type        = string
}

variable "firewall_name" {
  description = "Name of the HTTP/SSH ingress firewall rule."
  type        = string
}

variable "allowed_ssh_ranges" {
  description = "Source CIDRs allowed to SSH into tagged VMs. Avoid 0.0.0.0/0."
  type        = list(string)
}

variable "target_tags" {
  description = "Network tags the HTTP/SSH firewall rule targets."
  type        = list(string)
}

# ---------- GKE secondary ranges ----------

variable "pods_range_name" {
  description = "Name of the secondary IP range for GKE pod IPs."
  type        = string
  default     = "gke-pods"
}

variable "pods_cidr" {
  description = <<-EOT
    CIDR for GKE pod IPs. Needs to be large — each node borrows a /24 (256 IPs).
    A /16 supports ~256 nodes before exhaustion.
  EOT
  type        = string
  # e.g. "10.20.0.0/16"
}

variable "services_range_name" {
  description = "Name of the secondary IP range for GKE service (ClusterIP) IPs."
  type        = string
  default     = "gke-services"
}

variable "services_cidr" {
  description = "CIDR for GKE service IPs. A /20 gives 4096 ClusterIP addresses."
  type        = string
  # e.g. "10.30.0.0/20"
}
