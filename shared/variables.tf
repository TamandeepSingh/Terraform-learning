# ============================================================
# shared/variables.tf — Common variable definitions
# ============================================================
# This file is NOT a Terraform module — Terraform doesn't
# automatically source files from sibling directories.
#
# Purpose: single source of truth for *variable definitions*
# that are copy-pasted (or symlinked) into each environment.
# When you add a new environment (staging, prod), copy these
# declarations and supply new values in terraform.tfvars.
#
# Each environment's variables.tf should declare the same
# variables as here but can add environment-specific ones too.

# ---------------------------------------------------------------
# Project & Region
# ---------------------------------------------------------------

variable "project_id" {
  description = "GCP project ID for all resources."
  type        = string
}

variable "region" {
  description = "Default GCP region (e.g. us-central1)."
  type        = string
}

variable "zone" {
  description = "GCP zone for zonal resources like GCE VMs (e.g. us-central1-a)."
  type        = string
}

# ---------------------------------------------------------------
# Networking
# ---------------------------------------------------------------

variable "vpc_name" {
  description = "Name of the VPC network."
  type        = string
}

variable "subnet_name" {
  description = "Name of the subnet."
  type        = string
}

variable "subnet_cidr" {
  description = "Primary CIDR for the subnet. Nodes and VMs get IPs from here."
  type        = string
}

variable "pods_cidr" {
  description = "Secondary CIDR for GKE pod IPs. /16 supports up to 256 nodes."
  type        = string
}

variable "services_cidr" {
  description = "Secondary CIDR for GKE service (ClusterIP) IPs. /20 = 4096 services."
  type        = string
}

variable "firewall_name" {
  description = "Name of the HTTP/SSH ingress firewall rule."
  type        = string
}

variable "allowed_ssh_ranges" {
  description = "Source CIDRs allowed to SSH. Never use 0.0.0.0/0 in production."
  type        = list(string)
}

# ---------------------------------------------------------------
# GCE
# ---------------------------------------------------------------

variable "vm_name" {
  description = "Name of the Compute Engine web-server VM."
  type        = string
}

variable "machine_type" {
  description = "Machine type for the GCE VM. e2-micro is free-tier eligible."
  type        = string
}

variable "vm_image" {
  description = "Boot disk image family (e.g. debian-cloud/debian-12)."
  type        = string
}

variable "disk_size_gb" {
  description = "Boot disk size in GB for the GCE VM."
  type        = number
}

variable "vm_tags" {
  description = "Network tags for the GCE VM. Must match firewall target_tags."
  type        = list(string)
}

# ---------------------------------------------------------------
# GKE
# ---------------------------------------------------------------

variable "cluster_name" {
  description = "Name of the GKE cluster."
  type        = string
}

variable "master_ipv4_cidr_block" {
  description = "A /28 CIDR for the GKE control plane peered VPC. Must not overlap with other CIDRs."
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
  description = "Initial nodes per zone in the GKE node pool."
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
