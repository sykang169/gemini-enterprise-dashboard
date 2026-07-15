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

# ---------------------------------------------------------------------------
# Who the scheduled queries run as — shared by this file and archive.tf.
# ---------------------------------------------------------------------------
# *** A TRANSFER CONFIG MUST NAME A RUNNER — VERIFIED THE HARD WAY ***
# BigQuery Data Transfer Service refuses to create a scheduled query unless it
# knows what to run it as. It accepts exactly two answers: service_account_name
# (run as that SA), or version_info (an OAuth *refresh* token, i.e. run as the
# end user). Supply neither and CreateTransferConfig fails with
#   Error 400: Failed to find a valid credential.
#   The field 'version_info' or 'service_account_name' must be specified.
#
# deploy.sh authenticates the provider with
# `export GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token)"`, and a
# bare access token carries no refresh token — so the provider CANNOT produce
# version_info, no matter who runs it. service_account_name is therefore the
# only path that works under deploy.sh, which is why leaving it null was a
# guaranteed 400 rather than a "sensible default" (the old comment here claimed
# the empty string let DTS "use its own default behavior"; it does not).
#
# The default below resolves to the project's default Compute Engine service
# account. The project NUMBER is read from data.google_project rather than
# hardcoded, so this module still deploys to any project — a literal number
# would point every other project's schedules at this one's SA.
#
# CALLER NEEDS actAs. Naming an SA here means the principal running terraform
# must hold iam.serviceAccounts.actAs on it (roles/iam.serviceAccountUser, or
# project Owner). Without it, creation fails 403 with "does not have
# iam.serviceAccounts.actAs access". Grant it with:
#   gcloud iam service-accounts add-iam-policy-binding \
#     "$(terraform output -raw scheduled_query_service_account)" \
#     --member="user:YOU@example.com" --role="roles/iam.serviceAccountUser"
#
# The SA also needs whatever the query itself touches (BigQuery Data Editor on
# the datasets, plus Vertex AI User for the Gemini calls in sql/02). The default
# Compute Engine SA historically carries project Editor, which covers this; on
# projects created with the "no default SA grants" org policy it does not, and
# you must grant those roles or point var.scheduled_query_service_account at an
# SA that has them.
#
# Projects with the Compute Engine API never enabled have NO default compute SA.
# There is no sane fallback to pick for you there — set
# var.scheduled_query_service_account explicitly.
data "google_project" "this" {
  project_id = var.project_id
}

locals {
  scheduled_query_sa = (
    var.scheduled_query_service_account != ""
    ? var.scheduled_query_service_account
    : "${data.google_project.this.number}-compute@developer.gserviceaccount.com"
  )
}

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

  # Defaults to the project's default Compute Engine SA; override with
  # var.scheduled_query_service_account. Never null — see the header comment
  # for why a null here is a guaranteed 400, not a default.
  service_account_name = local.scheduled_query_sa

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
