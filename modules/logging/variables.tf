# ============================================================
# modules/logging/variables.tf
# ============================================================

variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "sink_name" {
  description = "Name of the Cloud Logging export sink."
  type        = string
  default     = "terraform-log-sink"
}

variable "log_bucket_name" {
  description = "Name of the GCS bucket to export logs into (must already exist)."
  type        = string
}

variable "log_filter" {
  description = <<-EOT
    Cloud Logging filter string. Empty string exports all logs.
    Example: "resource.type=\"k8s_container\" severity>=WARNING"
  EOT
  type        = string
  default     = ""
}
