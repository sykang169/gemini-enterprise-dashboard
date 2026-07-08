# =============================================================================
# Scheduled query (BigQuery Data Transfer Service) — daily content classification
# =============================================================================
# t_content_topics (and the v_topic_distribution / v_intent_distribution /
# v_sentiment_daily views built on top of it) does NOT refresh itself: unlike
# the v_* views in sql/01_create_views.sql, which are live SELECTs and always
# current, t_content_topics is an append-only table populated by running
# sql/02_content_classification.sql. Without something re-running that
# script on a schedule, the classification table silently goes stale as new
# logs arrive. This resource is that "something" — a recurring scheduled
# query, as an alternative/complement to the one-shot
# google_bigquery_job.run_content_classification in model_and_views.tf.
#
# Prerequisite (not managed by this module): enable the BigQuery Data
# Transfer Service API once, out of band:
#   gcloud services enable bigquerydatatransfer.googleapis.com --project=<project>
#
# IMPORTANT — an equivalent config already exists in the live project,
# created manually:
#   projects/YOUR_PROJECT_NUMBER/locations/us/transferConfigs/YOUR_TRANSFER_CONFIG_ID
#   ("Gemini Ent - Daily Content Classification", schedule "every day 18:00"
#   (UTC — that config was updated from "every 24 hours" to this fixed daily
#   time), runs under the default Compute Engine service account).
# Setting var.enable_scheduled_classification = true will create a SECOND,
# independent scheduled query unless you first `terraform import` the
# existing one into this resource address:
#   terraform import 'google_bigquery_data_transfer_config.daily_content_classification[0]' \
#     projects/YOUR_PROJECT_NUMBER/locations/us/transferConfigs/YOUR_TRANSFER_CONFIG_ID
# Running both the manual config and this Terraform-managed one at the same
# time double-runs (and double-bills) the classification script.

resource "google_bigquery_data_transfer_config" "daily_content_classification" {
  count = var.enable_scheduled_classification ? 1 : 0

  project        = var.project_id
  location       = var.bq_location
  display_name   = "Gemini Ent - Daily Content Classification"
  data_source_id = "scheduled_query"
  # BigQuery Data Transfer Service schedules are always evaluated in UTC.
  # Default "every day 18:00" = 18:00 UTC = 03:00 KST (next day). Adjust
  # var.scheduled_query_schedule if you want a different local time — just
  # remember to convert to UTC yourself, the API has no timezone parameter.
  schedule = var.scheduled_query_schedule

  # service_account_name left unset (empty string) uses BQ Data Transfer
  # Service's own default behavior; set var.scheduled_query_service_account
  # to impersonate a specific SA instead (must already have BigQuery Data
  # Editor + Vertex AI User where the classification query needs them).
  service_account_name = var.scheduled_query_service_account != "" ? var.scheduled_query_service_account : null

  # Reuses local.content_classification_sql (defined in model_and_views.tf)
  # rather than a bare file() call, so the project id / dataset ids embedded
  # in sql/02_content_classification.sql get rewritten to var.project_id /
  # var.analytics_dataset_id / var.dashboard_dataset_id here too — otherwise
  # deploying this module to a second project would schedule a query that
  # still reads/writes the original project's tables.
  params = {
    query = local.content_classification_sql
  }

  depends_on = [
    google_project_service.apis,
    google_bigquery_job.create_model_gemini_flash,
    google_bigquery_job.create_dashboard_views,
  ]
}
