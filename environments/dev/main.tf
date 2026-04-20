# ============================================================
# environments/dev/main.tf — Dev environment entry point
# ============================================================
# This is the "composition layer" — it wires modules together
# by passing the outputs of one module as inputs to another.
#
# Data flow between modules:
#
#   iam      ──── gke_node_sa_email ──────────────────► gke
#   vpc      ──── vpc_id, subnet_id ──────────────────► gce
#   vpc      ──── vpc_name, subnet_name, range names ──► gke
#   gke      ──── instance_group_urls ─────────────────► load_balancer
#   vpc      ──── vpc_name ─────────────────────────────► load_balancer
#   cicd_iam ──── wif_provider, wif_service_account ───► (GitHub Secrets — see outputs)
#
# Run order:
#   Terraform works out the dependency graph automatically.
#   module.iam, module.vpc, and module.cicd_iam run in parallel.
#   module.gce and module.gke run after module.vpc completes.
#   module.gke also waits for module.iam.
#   module.load_balancer waits for module.gke and module.vpc.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
  # Backend is declared in backend.tf (kept separate so it's easy to spot).
}

# The provider is configured once here at the environment level.
# All modules inherit this provider unless they declare their own.
provider "google" {
  project = var.project_id
  region  = var.region
}

# ---------------------------------------------------------------
# IAM — GKE node service account
# ---------------------------------------------------------------
# Created first (logically) because GKE needs the SA email.
# In practice Terraform figures out the order from references.
module "iam" {
  source = "../../modules/iam"

  project_id     = var.project_id
  gke_node_sa_id = "gke-node-sa-dev" # unique per environment
}

# ---------------------------------------------------------------
# CI/CD IAM — GitHub Actions service account + Workload Identity
# ---------------------------------------------------------------
# Enables GCR, creates the GitHub Actions SA, and wires up
# Workload Identity Federation so GitHub can push images and
# deploy to GKE without any stored credentials (no SA key).
#
# After apply, get the GitHub Secrets values with:
#   terraform output -raw cicd_wif_provider
#   terraform output -raw cicd_wif_service_account
module "cicd_iam" {
  source = "../../modules/cicd_iam"

  project_id  = var.project_id
  github_repo = var.github_repo   # e.g. "tsinghkhamba/gke-sample-app"
}

# ---------------------------------------------------------------
# VPC — networking foundation
# ---------------------------------------------------------------
# Everything (GCE VMs, GKE nodes) attaches to this VPC/subnet.
module "vpc" {
  source = "../../modules/vpc"

  vpc_name    = var.vpc_name
  subnet_name = var.subnet_name
  subnet_cidr = var.subnet_cidr
  region      = var.region

  firewall_name      = var.firewall_name
  allowed_ssh_ranges = var.allowed_ssh_ranges
  target_tags        = var.vm_tags # firewall targets these VM tags

  # Secondary IP ranges for GKE VPC-native networking.
  pods_range_name     = "gke-pods"
  pods_cidr           = var.pods_cidr
  services_range_name = "gke-services"
  services_cidr       = var.services_cidr
}

# ---------------------------------------------------------------
# GCE — web-server VM
# ---------------------------------------------------------------
# Attach to the VPC using outputs from the vpc module.
# Comment this block out if you only need GKE.
module "gce" {
  source = "../../modules/gce"

  vm_name      = var.vm_name
  machine_type = var.machine_type
  zone         = var.zone
  vm_tags      = var.vm_tags
  vm_image     = var.vm_image
  disk_size_gb = var.disk_size_gb
  environment  = "dev"

  # These values come from the vpc module — no hard-coded IDs needed.
  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.subnet_id
}

# ---------------------------------------------------------------
# GKE — Kubernetes cluster
# ---------------------------------------------------------------
# Networking comes from the vpc module; the node SA from the iam module.
# This ensures GKE is always in the same VPC as everything else.
module "gke" {
  source = "../../modules/gke"

  cluster_name = var.cluster_name
  region       = var.region
  project_id   = var.project_id

  # Network — passed from vpc module outputs.
  vpc_name            = module.vpc.vpc_name
  subnet_name         = module.vpc.subnet_name
  pods_range_name     = module.vpc.pods_range_name
  services_range_name = module.vpc.services_range_name

  master_ipv4_cidr_block = var.master_ipv4_cidr_block

  # Node SA — passed from iam module output.
  node_service_account = module.iam.gke_node_sa_email

  node_zones = var.node_zones

  # Node pool sizing.
  machine_type       = var.gke_machine_type
  disk_size_gb       = var.gke_disk_size_gb
  initial_node_count = var.initial_node_count
  min_node_count     = var.min_node_count
  max_node_count     = var.max_node_count
  environment        = "dev"
}

# ---------------------------------------------------------------
# Load Balancer — Global HTTP LB in front of GKE
# ---------------------------------------------------------------
# Creates the full GCP Application Load Balancer infrastructure.
# The LB routes external HTTP traffic to GKE nodes on var.node_port.
#
# After apply, deploy a Kubernetes Service of type NodePort:
#
#   apiVersion: v1
#   kind: Service
#   metadata:
#     name: my-app
#   spec:
#     type: NodePort
#     selector:
#       app: my-app
#     ports:
#       - port: 80
#         targetPort: 8080
#         nodePort: 30080   ← must match var.node_port
#
# The LB will start forwarding traffic once health checks pass.
module "load_balancer" {
  source = "../../modules/load_balancer"

  name_prefix = "dev-gke"

  # VPC name — the firewall rule for health checks attaches to this network.
  vpc_name = module.vpc.vpc_name

  # Map of zone → instance group URL. Keys (zones) are known at plan time,
  # which satisfies Terraform's requirement for static for_each keys.
  instance_group_urls = module.gke.instance_group_url_map

  node_port         = var.node_port
  health_check_path = "/"
}

# ---------------------------------------------------------------
# Logging — export logs to GCS
# ---------------------------------------------------------------
# Reuses the same GCS bucket as the Terraform state.
# In production you'd use a dedicated logging bucket.
module "logging" {
  source = "../../modules/logging"

  project_id      = var.project_id
  sink_name       = "dev-log-sink"
  log_bucket_name = "tamandeeps890-bucket"

  # Export only WARNING+ logs to keep GCS costs low in dev.
  # Change to "" to export everything.
  log_filter = "severity>=WARNING"
}

# ---------------------------------------------------------------
# Outputs — printed after terraform apply
# ---------------------------------------------------------------
output "vpc_id" {
  value = module.vpc.vpc_id
}

# CI/CD outputs — copy these values into GitHub Secrets
output "cicd_wif_provider" {
  description = "Paste this into GitHub Secret: WIF_PROVIDER"
  value       = module.cicd_iam.wif_provider
}

output "cicd_wif_service_account" {
  description = "Paste this into GitHub Secret: WIF_SERVICE_ACCOUNT"
  value       = module.cicd_iam.wif_service_account
}

output "cicd_gcr_registry_url" {
  description = "Base GCR URL — update IMAGE in ci-cd.yml to: <url>/calculator"
  value       = module.cicd_iam.gcr_registry_url
}

output "gke_cluster_name" {
  value = module.gke.cluster_name
}

output "gke_get_credentials" {
  description = "Run this to configure kubectl after apply."
  value       = module.gke.get_credentials_command
}

output "vm_external_ip" {
  description = "Apache web server external IP."
  value       = module.gce.vm_external_ip
}

output "load_balancer_ip" {
  description = "Static external IP of the GKE load balancer. Point your DNS A record here."
  value       = module.load_balancer.lb_ip
}

output "load_balancer_url" {
  description = "URL to test the load balancer — returns 502 until you deploy a NodePort Service."
  value       = module.load_balancer.lb_url
}
