# ============================================================
# modules/logging/outputs.tf
# ============================================================

output "sink_name" {
  description = "Name of the log sink."
  value       = google_logging_project_sink.gcs_sink.name
}

output "sink_writer_identity" {
  description = "SA email used by the sink to write to GCS. Useful for auditing IAM."
  value       = google_logging_project_sink.gcs_sink.writer_identity
}
