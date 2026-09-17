# =============================================================================
# Log Analytics enablement + linked BigQuery dataset
# =============================================================================
#
# Two steps are required to get from a plain Cloud Logging bucket to a
# queryable BigQuery dataset:
#   1. Enable Log Analytics on the log bucket (one-way switch, cannot be
#      disabled once enabled).
#   2. Create a "linked dataset" that exposes that bucket's logs as a
#      BigQuery dataset (here: gemini_ent_analytics, table _AllLogs).
#
# ---------------------------------------------------------------------------
# Why step 1 uses null_resource + local-exec instead of a native resource
# ---------------------------------------------------------------------------
# The google provider *does* expose `enable_analytics` on
# `google_logging_project_bucket_config`, e.g.:
#
#   resource "google_logging_project_bucket_config" "default_bucket" {
#     project          = var.project_id
#     location         = var.log_bucket_location
#     bucket_id        = var.log_bucket_name   # "_Default"
#     enable_analytics = true
#     retention_days   = 90                    # must match the LIVE value (currently 90 days on _Default)
#     # locked         = false                 # must match the LIVE value
#   }
#
# We deliberately do NOT use that resource here, for one concrete reason:
# `_Default` is a singleton bucket that already exists in every project and
# was NOT created by this Terraform config. Managing it as a full resource
# requires a `terraform import` first, and every field you don't set
# explicitly (retention_days, locked, cmek_settings, index_configs, ...) is
# still under Terraform's authority — a stale or incomplete import can cause
# an unrelated `terraform apply` to silently change retention policy on the
# project's default log bucket, which is a much bigger blast radius than
# "did Log Analytics get turned on". A local-exec that only ever runs one
# targeted `gcloud logging buckets update --enable-analytics` avoids that
# risk entirely, at the cost of the operation not showing up in
# `terraform plan`.
#
# If you later want the native-resource route, see the commented example
# above; run `terraform import google_logging_project_bucket_config.default_bucket
# projects/PROJECT/locations/global/buckets/_Default` first and reconcile
# every field with the live `gcloud logging buckets describe` output before
# applying.
#
# LIMITATIONS of the null_resource approach used below:
#   - Not idempotent-by-plan: `terraform plan` never shows this step, and
#     `terraform destroy` cannot undo it (Log Analytics cannot be disabled
#     via API anyway — this is a one-way switch regardless of tooling).
#   - Runs from whatever machine executes `terraform apply`; that principal
#     needs `roles/logging.admin` (or `logging.buckets.update`).
#   - Uses `triggers` keyed to the bucket/location so it only re-runs if you
#     change which bucket you're targeting, not on every apply.
# ---------------------------------------------------------------------------

resource "null_resource" "enable_log_analytics" {
  triggers = {
    project  = var.project_id
    bucket   = var.log_bucket_name
    location = var.log_bucket_location
  }

  provisioner "local-exec" {
    command = <<-EOT
      gcloud logging buckets update ${var.log_bucket_name} \
        --project=${var.project_id} \
        --location=${var.log_bucket_location} \
        --enable-analytics
    EOT
  }

  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# Linked dataset: exposes the _Default bucket's logs as
# gemini_ent_analytics._AllLogs in BigQuery.
# ---------------------------------------------------------------------------
# HISTORY IS BOUNDED BY RETENTION, NOT BY THE ENABLEMENT DATE. Logs already
# in the bucket before analytics was enabled are visible in _AllLogs too.
# Verified on the source project: enabled 2026-07-08 06:48 UTC (UpdateBucket
# audit log), yet _AllLogs returns rows from 2026-06-19 with no gap around the
# enablement date. What is lost for good is whatever had already aged out of
# retention.
#
# The description string below still says "Forward-only". It is left as-is on
# purpose: a Log Analytics link has no update API, so changing the description
# would force Terraform to destroy and recreate the linked dataset, breaking
# every view that reads _AllLogs mid-apply. Trust this comment, not that string.

resource "google_logging_linked_dataset" "gemini_ent_analytics" {
  parent      = "projects/${var.project_id}"
  location    = var.log_bucket_location
  bucket      = var.log_bucket_name
  link_id     = var.analytics_dataset_id
  description = "Log Analytics linked dataset for Gemini Enterprise user-activity + Model Armor sanitize-operations logs. Forward-only: only indexes logs written after Log Analytics was enabled on ${var.log_bucket_name}."

  depends_on = [null_resource.enable_log_analytics]
}
