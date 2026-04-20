# ============================================================
# environments/dev/variables.tf — Variable declarations for dev
# ============================================================
# These mirror shared/variables.tf. Values are supplied in
# terraform.tfvars (or via -var flags / TF_VAR_* env vars).

# ---------------------------------------------------------------
# Project & Region
# ---------------------------------------------------------------

variable "project_id" {
  description = "GCP project ID for all dev resources."
  type        = string
}

variable "region" {
  description = "GCP region for dev (e.g. us-central1)."
  type        = string
}

variable "zone" {
  description = "GCP zone for GCE VMs (e.g. us-central1-a)."
  type        = string
}

# ---------------------------------------------------------------
# Networking
# ---------------------------------------------------------------

variable "vpc_name" {
  description = "Name of the dev VPC."
  type        = string
}

variable "subnet_name" {
  description = "Name of the dev subnet."
  type        = string
}

variable "subnet_cidr" {
  description = "Primary CIDR for the dev subnet."
  type        = string
}

variable "pods_cidr" {
  description = "Secondary CIDR for GKE pod IPs in dev."
  type        = string
}

variable "services_cidr" {
  description = "Secondary CIDR for GKE service IPs in dev."
  type        = string
}

variable "firewall_name" {
  description = "Name of the HTTP/SSH firewall rule."
  type        = string
}

variable "allowed_ssh_ranges" {
  description = "Source CIDRs allowed to SSH into VMs."
  type        = list(string)
}

# ---------------------------------------------------------------
# GCE
# ---------------------------------------------------------------

variable "vm_name" {
  description = "Name of the dev web-server VM."
  type        = string
}

variable "machine_type" {
  description = "Machine type for the GCE VM."
  type        = string
}

variable "vm_image" {
  description = "Boot image for the GCE VM."
  type        = string
}

variable "disk_size_gb" {
  description = "Boot disk size in GB for the GCE VM."
  type        = number
}

variable "vm_tags" {
  description = "Network tags for the GCE VM."
  type        = list(string)
}

# ---------------------------------------------------------------
# GKE
# ---------------------------------------------------------------

variable "cluster_name" {
  description = "Name of the dev GKE cluster."
  type        = string
}

variable "node_zones" {
  description = "Zones for GKE worker nodes (must be within var.region)."
  type        = list(string)
}

variable "master_ipv4_cidr_block" {
  description = "/28 CIDR for GKE control plane peered VPC. Must not overlap other CIDRs."
  type        = string
}

variable "gke_machine_type" {
  description = "Machine type for GKE worker nodes."
  type        = string
}

variable "gke_disk_size_gb" {
  description = "Boot disk size per GKE node in GB."
  type        = number
}

variable "initial_node_count" {
  description = "Starting nodes per zone in the node pool."
  type        = number
}

variable "min_node_count" {
  description = "Autoscaler minimum nodes per zone."
  type        = number
}

variable "max_node_count" {
  description = "Autoscaler maximum nodes per zone."
  type        = number
}

# ---------------------------------------------------------------
# Load Balancer
# ---------------------------------------------------------------

variable "node_port" {
  description = <<-EOT
    Kubernetes NodePort that the LB routes traffic to on each GKE node.
    Must match the nodePort field in your Kubernetes Service spec.
    Valid range: 30000–32767.
  EOT
  type    = number
  default = 30080
}

# ---------------------------------------------------------------
# CI/CD
# ---------------------------------------------------------------

variable "github_repo" {
  description = <<-EOT
    GitHub repository in "owner/repo" format.
    Example: "tsinghkhamba/gke-sample-app"
    Used by the Workload Identity Provider's attribute_condition to ensure
    only this repo's GitHub Actions workflows can impersonate the CI/CD SA.
  EOT
  type = string
}
