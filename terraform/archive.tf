# =============================================================================
# ③ OPT-IN: durable log archive (sql/03_archive_logs.sql)
# =============================================================================
#
# THE PROBLEM THIS SOLVES
# -----------------------
# gemini_ent_analytics._AllLogs is a LINKED dataset — a VIEW over the _Default
# log bucket that stores 0 bytes of its own (verified: type=VIEW, numBytes=0).
# That is why this dashboard has no BigQuery storage bill and is always fresh.
# The flip side: the log bucket's retention IS the dashboard's memory. At the
# default 30 days, every view silently becomes a 30-day rolling window, and
# expired rows are gone — Log Analytics has no backfill.
#
# This copies the logs the views actually read into a real partitioned table
# with the SAME schema, so history outlives retention. See the header of
# sql/03_archive_logs.sql for the filtering, dedup-key, and late-arrival
# reasoning (all of it verified against 7.3M live rows).
#
# WHY OPT-IN (default false), despite being cheap
# -----------------------------------------------
# Storage is genuinely negligible — the filter keeps ~11 MB per 38 days, versus
# 20.6 GB unfiltered. The reason it is opt-in is governance, not cost: with
# var.enable_sensitive_logging on, these rows contain end-user prompts and
# identities in the clear, and archiving them means that PII now OUTLIVES the
# log bucket's retention policy. Deciding "prompt text is retained forever"
# must be deliberate. Before enabling, confirm your retention obligations and
# lock down IAM on var.dashboard_dataset_id.
#
# START IT EARLY. The archive can only preserve what the bucket still holds;
# turning it on at day 45 of a 30-day retention means days 1-15 are already
# unrecoverable. It is the one flag whose value depends on being set BEFORE
# you need it.
#
# ONE-SHOT vs SCHEDULED
# ---------------------
#   var.enable_log_archive           -> google_bigquery_job below. job_id is
#     keyed to the SQL's sha256, so it runs ONCE per unique script: it creates
#     the table and backfills whatever is currently in the retention window.
#     It does NOT keep running on later applies (same SQL = same job_id = no-op).
#   var.enable_scheduled_archive     -> the daily transfer config below, which
#     is what actually keeps the archive current. Enabling the one-shot without
#     the schedule gives you a snapshot that immediately starts going stale.
# Enable both unless you have a reason not to.

resource "google_bigquery_job" "archive_logs" {
  count = var.enable_log_archive ? 1 : 0

  project  = var.project_id
  location = var.bq_location
  job_id   = local.archive_logs_job_id

  query {
    query              = local.archive_logs_sql
    use_legacy_sql     = false
    create_disposition = ""
    write_disposition  = ""
  }

  depends_on = [
    google_project_service.apis,
    google_bigquery_dataset.gemini_ent_dashboard,
    google_logging_linked_dataset.gemini_ent_analytics,
  ]
}

# ---------------------------------------------------------------------------
# Daily incremental archive.
# ---------------------------------------------------------------------------
# Unlike the content-classification schedule (scheduled_query.tf), this one is
# safe to run often: it calls no Gemini endpoint, and the MERGE key makes a
# re-run over an already-archived window insert nothing. The only per-run cost
# is scanning the lookback window of _AllLogs.
#
# Scheduled at 17:00 UTC (02:00 KST) — one hour ahead of the default
# classification schedule (18:00 UTC), so a day's logs are archived before the
# classifier reads them.

resource "google_bigquery_data_transfer_config" "daily_log_archive" {
  count = var.enable_scheduled_archive ? 1 : 0

  project        = var.project_id
  location       = var.bq_location
  display_name   = "Gemini Ent - Daily Log Archive"
  data_source_id = "scheduled_query"

  # BigQuery Data Transfer Service schedules are always evaluated in UTC —
  # there is no timezone parameter. Convert your local time yourself.
  schedule = var.archive_schedule

  # Defaults to the project's default Compute Engine SA. local.scheduled_query_sa
  # and the reasoning behind it live in scheduled_query.tf — a transfer config
  # with no runner is a hard 400, not a default.
  service_account_name = local.scheduled_query_sa

  # Reuses local.archive_logs_sql (model_and_views.tf) rather than a bare
  # file() call, so the project/dataset placeholders inside sql/03 are
  # rewritten for THIS project — otherwise a second deployment would schedule
  # a query that archives the first project's logs.
  params = {
    query = local.archive_logs_sql
  }

  depends_on = [
    google_project_service.apis,
    google_bigquery_dataset.gemini_ent_dashboard,
    google_logging_linked_dataset.gemini_ent_analytics,
  ]
}
