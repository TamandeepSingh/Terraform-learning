# ============================================================
# environments/dev/terraform.tfvars — Actual variable values for dev
# ============================================================
# This file is automatically loaded by Terraform when you run
# plan / apply from the environments/dev/ directory.
#
# ⚠ Do NOT commit secrets (passwords, keys) in this file.
#   Use Secret Manager or env vars (TF_VAR_*) for sensitive values.
#
# Replace YOUR_PROJECT_ID with your real GCP project ID.

# ---------------------------------------------------------------
# Project & Region
# ---------------------------------------------------------------
project_id = "project-efaf083d-e292-4f24-a27" # Replace with your actual GCP project ID
region     = "us-central1"
zone       = "us-central1-a"

# ---------------------------------------------------------------
# Networking
# ---------------------------------------------------------------
vpc_name    = "my-custom-vpc"
subnet_name = "my-subnet"
subnet_cidr = "10.10.0.0/24" # 256 host addresses in this subnet

# Secondary ranges for GKE VPC-native networking.
# These must not overlap with subnet_cidr or master_ipv4_cidr_block.
pods_cidr     = "10.20.0.0/16" # /16 → 65 536 pod IPs (enough for ~256 nodes)
services_cidr = "10.30.0.0/20" # /20 → 4 096 ClusterIP addresses

firewall_name = "allow-http-ssh"

# Replace with your own IP (curl ifconfig.me) to restrict SSH access.
allowed_ssh_ranges = ["0.0.0.0/0"]

# ---------------------------------------------------------------
# GCE (web-server VM)
# ---------------------------------------------------------------
vm_name      = "web-server-1"
machine_type = "e2-medium"       # 2 vCPU burst, 1 GB RAM — free-tier eligible
vm_image     = "ubuntu-minimal-2404-noble-amd64-v20260415"
disk_size_gb = 10
vm_tags      = ["http-server", "ssh-server"]

# ---------------------------------------------------------------
# GKE
# ---------------------------------------------------------------
cluster_name = "dev-gke-cluster"
node_zones   = ["us-central1-a", "us-central1-b", "us-central1-c"]

# /28 for the control plane peered VPC — must not overlap above CIDRs.
master_ipv4_cidr_block = "172.16.0.0/28"

gke_machine_type = "e2-medium"  # 2 vCPU, 4 GB — good for dev workloads
gke_disk_size_gb = 50

# Regional cluster (3 zones) → actual node count = initial_node_count × 3 = 3 total
initial_node_count = 1
min_node_count     = 1
max_node_count     = 3

# ---------------------------------------------------------------
# Load Balancer
# ---------------------------------------------------------------
# Must match the nodePort in your Kubernetes Service spec.
node_port = 30080

# ---------------------------------------------------------------
# CI/CD
# ---------------------------------------------------------------
# GitHub repo that is allowed to impersonate the CI/CD service account.
# Replace with your actual GitHub username and repo name.
github_repo = "your-github-username/gke-sample-app"
