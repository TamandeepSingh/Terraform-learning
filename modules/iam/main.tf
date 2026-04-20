# ============================================================
# modules/iam/main.tf — GKE node service account
# ============================================================
# GKE worker nodes run as a Google Service Account (GSA). By default
# GKE uses the Compute Engine default SA which has very broad "Editor"
# permissions — a security risk.
#
# Best practice: create a *dedicated, minimal* SA for GKE nodes and
# grant only the roles the nodes actually need. This limits the blast
# radius if a node is ever compromised.
#
# Minimum roles for GKE nodes:
#   roles/logging.logWriter       — write logs to Cloud Logging
#   roles/monitoring.metricWriter — write metrics to Cloud Monitoring
#   roles/monitoring.viewer       — read monitoring data (sidecars need this)
#   roles/artifactregistry.reader — pull container images from Artifact Registry
#
# If you pull images from Docker Hub or other public registries you will
# also need Cloud NAT on the subnet (nodes have no public IP in a private
# cluster). Artifact Registry pulls work via private_ip_google_access.

resource "google_service_account" "gke_node_sa" {
  account_id   = var.gke_node_sa_id
  display_name = "GKE Node Service Account"
  description  = "Minimal SA for GKE worker nodes. Managed by Terraform."
  project      = var.project_id
}

# locals{} keeps the role list easy to extend without touching resource blocks.
locals {
  gke_node_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/artifactregistry.reader",
  ]
}

# for_each iterates over the role list, creating one IAM binding per role.
# toset() converts the list to a set — for_each requires a map or set as input.
# each.value holds the current role string on each iteration.
resource "google_project_iam_member" "gke_node_sa_roles" {
  for_each = toset(local.gke_node_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.gke_node_sa.email}"
}
