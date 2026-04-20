# ============================================================
# modules/load_balancer/variables.tf
# ============================================================

variable "name_prefix" {
  description = "Prefix applied to every resource name in this module (e.g. 'dev-gke')."
  type        = string
}

variable "vpc_name" {
  description = <<-EOT
    Short name of the VPC network.
    Used by the firewall rule — pass module.vpc.vpc_name from the environment.
  EOT
  type        = string
}

variable "instance_group_urls" {
  description = <<-EOT
    Map of zone → GKE node-pool instance group self-link URL (one entry per zone).
    Pass module.gke.instance_group_url_map from the environment.
    Using a map (instead of a list/set) lets for_each use zone names as static keys,
    since Terraform requires for_each keys to be known at plan time.
  EOT
  type        = map(string)
}

variable "node_port" {
  description = <<-EOT
    The Kubernetes NodePort that your Service exposes on every node.
    The LB routes traffic to this port; kube-proxy forwards it to pods.
    Must be in the range 30000–32767 (Kubernetes default NodePort range).
  EOT
  type        = number
  default     = 30080
}

variable "health_check_path" {
  description = <<-EOT
    HTTP path the health checker GETs on each node.
    Set this to your app's readiness endpoint (e.g. "/healthz", "/ready").
    Until your app is deployed the LB will return 502 — that's expected.
  EOT
  type        = string
  default     = "/"
}
