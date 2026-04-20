# ============================================================
# modules/gke/variables.tf
# ============================================================

variable "cluster_name" {
  description = "Name of the GKE cluster."
  type        = string
}

variable "region" {
  description = "GCP region. A regional cluster creates control-plane replicas in each zone."
  type        = string
}

variable "project_id" {
  description = "GCP project ID. Used to construct the Workload Identity pool name."
  type        = string
}

# ---------- Networking (sourced from vpc module outputs) ----------

variable "vpc_name" {
  description = "VPC name. Use module.vpc.vpc_name."
  type        = string
}

variable "subnet_name" {
  description = "Subnet name. Use module.vpc.subnet_name."
  type        = string
}

variable "pods_range_name" {
  description = "Secondary range name for pod IPs. Use module.vpc.pods_range_name."
  type        = string
}

variable "services_range_name" {
  description = "Secondary range name for service IPs. Use module.vpc.services_range_name."
  type        = string
}

variable "master_ipv4_cidr_block" {
  description = <<-EOT
    A /28 CIDR reserved for the GKE control plane's peered VPC.
    Must not overlap with subnet_cidr, pods_cidr, or services_cidr.
    Common safe choice: 172.16.0.0/28
  EOT
  type        = string
  default     = "172.16.0.0/28"
}

# ---------- IAM (sourced from iam module output) ----------

variable "node_service_account" {
  description = "Email of the GKE node SA. Use module.iam.gke_node_sa_email."
  type        = string
}

# ---------- Node pool sizing ----------

variable "machine_type" {
  description = "GCE machine type for worker nodes. e2-medium is a good dev starting point."
  type        = string
  default     = "e2-medium"
}

variable "disk_size_gb" {
  description = "Boot disk size per node in GB."
  type        = number
  default     = 50
}

variable "initial_node_count" {
  description = "Initial nodes per zone. Autoscaler will adjust after that."
  type        = number
  default     = 1
}

variable "min_node_count" {
  description = "Autoscaler minimum nodes per zone."
  type        = number
  default     = 1
}

variable "max_node_count" {
  description = "Autoscaler maximum nodes per zone."
  type        = number
  default     = 3
}

variable "environment" {
  description = "Environment label applied to nodes."
  type        = string
  default     = "dev"
}

variable "node_zones" {
  description = <<-EOT
    Explicit list of zones for GKE worker nodes (e.g. ["us-central1-a", "us-central1-b", "us-central1-c"]).
    Must be within var.region. Making zones explicit allows the load_balancer module to build
    a map(string) for for_each, since map keys must be known at plan time.
  EOT
  type        = list(string)
}
