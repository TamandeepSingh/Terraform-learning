# ============================================================
# environments/dev/backend.tf — Remote state (GCS)
# ============================================================
# Terraform state is a JSON file tracking every resource Terraform
# manages. Storing it in GCS (instead of locally) means:
#
#   • Shared state — teammates always operate on the same state.
#   • Durability   — state survives a wiped laptop.
#   • Versioning   — GCS versioning lets you roll back to a previous state
#                    if something goes wrong during apply.
#   • Locking      — GCS backend uses a lock object to prevent concurrent
#                    applies from corrupting state.
#
# ⚠ The backend block cannot use variables or locals — all values must
# be literal strings. This is a Terraform restriction because the
# backend is initialised before variables are evaluated.
#
# Each environment uses a different 'prefix' (folder path inside the bucket)
# so state files don't collide:
#   dev  → terraform/state/dev/default.tfstate
#   prod → terraform/state/prod/default.tfstate

terraform {
  backend "gcs" {
    bucket = "tamandeeps890-bucket"  # your GCS bucket (created separately)
    prefix = "terraform/state/dev"   # unique path per environment
  }
}
