# =============================================================================
# Remote model + dashboard views
# =============================================================================
# google_bigquery_job runs a query/script exactly once per distinct job_id;
# BigQuery jobs are immutable, so re-running the *same* DDL requires a *new*
# job_id. We derive job_id from a hash of the rendered SQL text: unchanged
# SQL -> unchanged job_id -> `terraform plan` shows no diff (truly
# idempotent); edit the SQL -> hash changes -> Terraform replaces the job
# resource -> the new script actually executes. This is the standard pattern
# for driving BigQuery DDL/DML through google_bigquery_job.
#
# Ordering: APIs -> dataset -> connection -> IAM -> [IAM propagation wait] ->
# model -> views, enforced via explicit depends_on (the model DDL needs the
# connection + IAM binding to already exist so the CREATE MODEL call can
# reach Vertex AI; the views don't strictly need the model, but keeping them
# last matches the manual build order and this repo's sql/ script split).
#
# IAM propagation wait (one-shot-deploy reliability): granting
# roles/aiplatform.user on the connection's service account does not take
# effect on Vertex AI instantly. Measured on this project: applying
# CREATE MODEL ... REMOTE WITH CONNECTION immediately after the IAM binding
# reliably fails with a permission-denied error; propagation takes 5+
# minutes. time_sleep.wait_for_iam_propagation forces a 300s pause between
# the IAM grant and the model-creation job so a fresh `terraform apply`
# against an empty project succeeds in one shot instead of requiring a
# manual re-run after waiting.
resource "time_sleep" "wait_for_iam_propagation" {
  create_duration = "300s"

  depends_on = [
    google_project_iam_member.gemini_conn_aiplatform_user,
  ]
}

locals {
  # ENDPOINT is var.gemini_endpoint (default gemini-2.5-flash-lite). See the
  # variable's description for the verified-working vs. "not found" endpoint
  # list on this project — do not swap in a gemini-2.0-* endpoint without
  # re-verifying.
  #
  # create_model_sql is already fully parameterized (built from HCL
  # variables, no file() involved), so it deploys to any project unchanged.
  create_model_sql = <<-SQL
    CREATE OR REPLACE MODEL `${var.project_id}.${var.dashboard_dataset_id}.${var.model_name}`
    REMOTE WITH CONNECTION `${var.project_id}.${var.bq_location}.${var.connection_id}`
    OPTIONS (ENDPOINT = '${var.gemini_endpoint}');
  SQL

  # sql/01_create_views.sql and sql/02_content_classification.sql use the
  # placeholder token `YOUR_PROJECT_ID` (and the default dataset ids
  # gemini_ent_analytics / gemini_ent_dashboard) in their fully-qualified
  # table names, so the repo is safe to publish publicly with no real
  # project identifiers baked in.
  #
  # When Terraform injects these files into a google_bigquery_job, it rewrites
  # those placeholders to whatever var.project_id (and dataset ids) THIS apply
  # targets, via `replace()` at plan time before the SQL is sent to BigQuery.
  # To run the .sql standalone (e.g. `bq query < sql/01_create_views.sql`),
  # substitute YOUR_PROJECT_ID with your real project id first.
  create_views_sql = replace(
    replace(
      replace(
        file("${path.module}/../sql/01_create_views.sql"),
        "YOUR_PROJECT_ID", var.project_id
      ),
      "gemini_ent_analytics", var.analytics_dataset_id
    ),
    "gemini_ent_dashboard", var.dashboard_dataset_id
  )

  content_classification_sql = replace(
    replace(
      replace(
        file("${path.module}/../sql/02_content_classification.sql"),
        "YOUR_PROJECT_ID", var.project_id
      ),
      "gemini_ent_analytics", var.analytics_dataset_id
    ),
    "gemini_ent_dashboard", var.dashboard_dataset_id
  )
}

# ---------------------------------------------------------------------------
# (a) Remote model DDL
# ---------------------------------------------------------------------------
resource "google_bigquery_job" "create_model_gemini_flash" {
  project  = var.project_id
  location = var.bq_location
  job_id   = "create_model_${var.model_name}_${substr(sha256(local.create_model_sql), 0, 10)}"

  query {
    query              = local.create_model_sql
    use_legacy_sql     = false
    create_disposition = ""
    write_disposition  = ""
  }

  depends_on = [
    google_project_service.apis,
    google_bigquery_dataset.gemini_ent_dashboard,
    google_bigquery_connection.gemini_conn,
    google_project_iam_member.gemini_conn_aiplatform_user,
    time_sleep.wait_for_iam_propagation,
  ]
}

# ---------------------------------------------------------------------------
# (b) Dashboard views (multi-statement script, sql/01_create_views.sql)
# ---------------------------------------------------------------------------
resource "google_bigquery_job" "create_dashboard_views" {
  project  = var.project_id
  location = var.bq_location
  job_id   = "create_dashboard_views_${substr(sha256(local.create_views_sql), 0, 10)}"

  query {
    query              = local.create_views_sql
    use_legacy_sql     = false
    create_disposition = ""
    write_disposition  = ""
  }

  depends_on = [
    google_project_service.apis,
    google_bigquery_dataset.gemini_ent_dashboard,
    google_logging_linked_dataset.gemini_ent_analytics,
    google_bigquery_job.create_model_gemini_flash,
  ]
}

# ---------------------------------------------------------------------------
# (c) OPT-IN: ② content classification (sql/02_content_classification.sql)
# ---------------------------------------------------------------------------
# Cost warning: this script calls ML.GENERATE_TEXT against gemini_flash once
# per not-yet-classified prompt row (incremental — see the script's own
# COALESCE(MAX(timestamp), ...) guard). Every `terraform apply` with
# enable_content_classification = true re-runs the incremental INSERT, which
# means every apply after new prompts have arrived spends Gemini calls. Keep
# this false for routine infra applies; flip it on deliberately.
resource "google_bigquery_job" "run_content_classification" {
  count = var.enable_content_classification ? 1 : 0

  project  = var.project_id
  location = var.bq_location
  # No hash-based job_id here: this script is meant to be re-run repeatedly
  # (it's an incremental batch job, not a one-shot DDL), so we key job_id on
  # time instead, meaning every `terraform apply` with the flag on triggers
  # a fresh classification pass over new rows.
  job_id = "run_content_classification_${formatdate("YYYYMMDD-hhmmss", timestamp())}"

  query {
    query              = local.content_classification_sql
    use_legacy_sql     = false
    create_disposition = ""
    write_disposition  = ""
  }

  depends_on = [
    google_bigquery_job.create_dashboard_views,
  ]

  lifecycle {
    # timestamp()-based job_id always differs -> would otherwise force a
    # "replacement" plan on every apply even when nothing else changed.
    # ignore_changes keeps that diff out of routine plans; run
    # `terraform apply -replace=google_bigquery_job.run_content_classification[0]`
    # (with enable_content_classification=true) when you deliberately want a
    # fresh classification pass.
    ignore_changes = [job_id]
  }
}
