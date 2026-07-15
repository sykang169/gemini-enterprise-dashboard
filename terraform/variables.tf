# =============================================================================
# Variables
# =============================================================================

variable "project_id" {
  description = <<-EOT
    GCP project that will host (or already hosts) the Gemini Enterprise +
    Model Armor logs and the dashboard BigQuery assets.

    Required, no default on purpose: this is the one value you must always
    pass explicitly (`terraform apply -var="project_id=<PROJECT>"` or via
    terraform.tfvars — see terraform.tfvars.example), so a one-shot deploy
    can never accidentally land in the wrong project. Every other variable
    in this file has a sensible default so a fresh/empty project only needs
    this one value set.
  EOT
  type        = string
}

variable "region" {
  description = "Default region for the google provider (only used for provider-level defaults; BigQuery resources use var.bq_location instead)."
  type        = string
  default     = "us-central1"
}

variable "bq_location" {
  description = "BigQuery multi-region location for all datasets, the BQ connection, and the remote model. Must match the location of gemini_ent_analytics._AllLogs (US) so cross-dataset views can join without a location mismatch error."
  type        = string
  default     = "US"
}

variable "dashboard_dataset_id" {
  description = "Dataset that holds the dashboard views (v_*), the content-classification table, and the remote model."
  type        = string
  default     = "gemini_ent_dashboard"
}

variable "analytics_dataset_id" {
  description = "Log Analytics linked dataset id (also used as the link_id for google_logging_linked_dataset). Contains the _AllLogs table that every dashboard view reads from."
  type        = string
  default     = "gemini_ent_analytics"
}

variable "log_bucket_name" {
  description = "Log bucket that Log Analytics is enabled on. Must be a bucket that has _Default-style routing for the sources listed in var.log_name_patterns, at the location in var.log_bucket_location."
  type        = string
  default     = "_Default"
}

variable "log_bucket_location" {
  description = "Location of the log bucket referenced by var.log_bucket_name. '_Default' always lives in 'global'."
  type        = string
  default     = "global"
}

variable "connection_id" {
  description = "BigQuery Cloud Resource connection id used to call Vertex AI (Gemini) from BigQuery ML."
  type        = string
  default     = "gemini_conn"
}

variable "model_name" {
  description = "Remote model name (BigQuery ML) that wraps the Vertex AI Gemini endpoint."
  type        = string
  default     = "gemini_flash"
}

variable "looker_studio_template_report_id" {
  description = <<-EOT
    Looker Studio TEMPLATE report id used to auto-generate a fully-built
    dashboard (charts already laid out) for this project via the Linking API's
    template-clone mode.

    Looker Studio has NO API to create charts from scratch, so a complete
    dashboard can only be produced by cloning a template report you built once.
    One-time setup:
      1. Deploy this module, then build the dashboard once by hand following
         looker_studio_setup.md (add the v_* views, arrange charts). All data
         sources must be BigQuery tables in var.dashboard_dataset_id.
      2. Copy the report id from the report URL (the segment between
         /reporting/ and /page) and set it here.

    The generated clone URL uses the ds.* wildcard to repoint only the project
    (keeping the template's dataset + table/view names), so data-source aliases
    do NOT need to match view names.

    Once set, `terraform output looker_studio_url` returns a deep link that
    clones that template into this project. Leave empty ("") to skip URL
    generation and get manual setup instructions instead.
  EOT
  type        = string
  default     = ""
}

variable "gemini_endpoint" {
  description = <<-EOT
    Vertex AI generative model endpoint backing the remote model gemini_flash.
    Default is gemini-2.5-flash-lite for cost reasons (Flash-Lite is
    materially cheaper per call than Flash, and this endpoint is hit once per
    row during content classification).

    VERIFIED IN THIS PROJECT (YOUR_PROJECT_ID): as of 2026-07,
    `gemini-2.0-flash`, `gemini-2.0-flash-lite`, and `gemini-2.0-flash-001`
    all fail with a "not found" error against this project's remote-model
    connection. Only `gemini-2.5-flash-lite` and `gemini-2.5-flash` have been
    confirmed to work. Do not revert to a 2.0-series endpoint without
    re-verifying against the live connection first.
  EOT
  type        = string
  default     = "gemini-2.5-flash-lite"
}

variable "enable_sensitive_logging" {
  description = <<-EOT
    Opt-in flag that PATCHes observabilityConfig.sensitiveLoggingEnabled on
    every targeted Gemini Enterprise engine (see sensitive_logging.tf), which
    is what makes prompts, responses, and real user identities appear in the
    logs as plain text instead of the 8-char token `<elided>`.

    Without this, the following views exist but are empty or collapse onto a
    single `<elided>` user: v_user_questions, v_queries_per_user,
    v_daily_active_users, v_user_activity_detail, v_user_agent_trace — and
    sql/02 content classification has no question text to classify.

    FORWARD-ONLY: enabling this does NOT backfill. Logs already written with
    `<elided>` stay masked permanently. Enable it AT DEPLOY TIME if you want
    prompt-level analytics at all:
      ./deploy.sh <PROJECT_ID> -var="enable_sensitive_logging=true"

    Defaults to false because it writes end-user PII in the clear into Cloud
    Logging and, via the linked dataset, into BigQuery. Lock down IAM on the
    analytics + dashboard datasets before turning it on.
  EOT
  type        = bool
  default     = false
}

variable "sensitive_logging_engine_ids" {
  description = <<-EOT
    Gemini Enterprise engine ids to apply var.enable_sensitive_logging to,
    e.g. ["my-app_1782188315701"]. Engines are assumed to live at
    locations/global under collections/default_collection.

    Empty list (the default) = AUTO MODE: unmask only the engines that are
    ALREADY emitting logs (observabilityEnabled=true). Those are exactly the
    engines already feeding _AllLogs, so nothing new starts being logged and
    no new bill appears — their rows just stop coming through as `<elided>`.
    Engines with observability off are listed and skipped.

    Naming engines explicitly = EXPLICIT MODE: force BOTH observabilityEnabled
    and sensitiveLoggingEnabled on for those engines, i.e. start logging an
    engine that was not logging before. Use this for a fresh app that has
    never had observability turned on.

    Auto mode deliberately does not touch every engine in the project: a
    Gemini Enterprise project routinely holds unrelated search/parser/KB
    engines, and force-enabling observability on all of them would start
    billable log volume and write their users' prompts in the clear.

    Individual agents inherit observabilityConfig from their parent engine —
    there is nothing to set per-agent.

    Ignored entirely when var.enable_sensitive_logging is false.
  EOT
  type        = list(string)
  default     = []
}

variable "dashboard_window_days" {
  description = <<-EOT
    How many days back the dashboard views (v_log_source, and therefore every
    v_* chart view) read from the archive. Default 90.

    WHY A BOUND EXISTS: t_logs_archive is append-only forever, so without one
    every chart's scan grows for the life of the deployment — a 3-year-old
    install would scan 3 years of logs to draw "queries per day" on every
    refresh. The bound keeps chart cost flat instead of growing with age.

    This does NOT shrink the archive or drop history. The table keeps
    everything; v_log_source_all reads it unbounded for ad-hoc/compliance
    queries. This only bounds what the charts reach for by default.

    A Looker report with a date-range control already prunes on its own
    (verified: filtering the aggregate views' `day` column still prunes
    partitions). This default is the safety net for a chart placed on a page
    with no date control, which sends no filter at all.

    Sized against retention: the log bucket keeps 30 days, so 90 still shows
    3x what the logs alone could. Set 0 for unbounded (charts then scan the
    full archive — only sensible if you deliberately want multi-year trends on
    the dashboard).
  EOT
  type        = number
  default     = 90

  validation {
    condition     = var.dashboard_window_days >= 0
    error_message = "dashboard_window_days must be 0 (unbounded) or a positive number of days."
  }
}

variable "enable_log_archive" {
  description = <<-EOT
    Opt-in flag for the ③ log archive (sql/03_archive_logs.sql, archive.tf):
    a real partitioned table (t_logs_archive) holding a durable copy of the
    logs the dashboard reads, with the same schema as _AllLogs.

    WHY YOU LIKELY WANT THIS: _AllLogs is a VIEW over the _Default log bucket
    and stores nothing itself, so the bucket's retention (30 days by default)
    is the hard limit on how far back ANY view can see. Expired logs are gone
    — there is no backfill. This table is the only thing that outlives it.

    Cost is negligible: the script archives only the logs the views read
    (~11 MB per 38 days on the source project, vs 20.6 GB unfiltered). It is
    opt-in for governance, not cost — with var.enable_sensitive_logging on,
    the archived rows contain end-user prompts and identities in the clear,
    so this makes that PII outlive the log bucket's retention policy.

    START IT EARLY: the archive can only save what the bucket still holds.
    Enabling it after retention has already expired does not bring data back.

    This one-shot job creates + backfills the table; pair it with
    var.enable_scheduled_archive to keep it current.
  EOT
  type        = bool
  default     = false
}

variable "enable_scheduled_archive" {
  description = <<-EOT
    Opt-in flag for the daily incremental archive run (a BigQuery Data
    Transfer Service scheduled query, see archive.tf). Without this, the
    archive is a one-time snapshot that starts going stale immediately.

    Safe to run repeatedly: it calls no Gemini endpoint (unlike
    var.enable_scheduled_classification), and the MERGE key
    (log_name, timestamp, insert_id) makes re-running over an already-archived
    window a no-op. Per-run cost is just scanning the lookback window.

    Requires bigquerydatatransfer.googleapis.com (enabled by apis.tf).
  EOT
  type        = bool
  default     = false
}

variable "archive_schedule" {
  description = <<-EOT
    BigQuery Data Transfer Service schedule for the daily log archive
    (archive.tf). Default "every day 17:00".

    Hourly by default, because the dashboard now reads ONLY the archive
    (see v_log_source in sql/01) -- this schedule IS the dashboard's refresh
    rate, and its worst-case staleness.

    Hourly is affordable only because sql/03's lookback was sized to match
    (3h): the job pays for every hour of window it scans. Do not widen the
    schedule interval past the lookback, or rows will be skipped on the happy
    path; widen the lookback first.

    Evaluated in UTC — the API has no timezone parameter.
  EOT
  type        = string
  default     = "every 1 hours"
}

variable "enable_content_classification" {
  description = "Opt-in flag for the ② content-classification pipeline (sql/02_content_classification.sql) run via a one-shot google_bigquery_job. Each apply with this set to true runs an incremental Gemini classification pass over any unclassified prompts, which calls the Gemini endpoint once per row and therefore incurs cost on every apply. Leave false for routine applies; flip to true only when you intentionally want to (re)run the classification batch. For a recurring daily run instead of a one-shot apply-time run, see var.enable_scheduled_classification below."
  type        = bool
  default     = false
}

variable "enable_scheduled_classification" {
  description = <<-EOT
    Opt-in flag for a daily BigQuery Data Transfer Service scheduled query
    (google_bigquery_data_transfer_config, see scheduled_query.tf) that runs
    sql/02_content_classification.sql on a recurring schedule (see
    var.scheduled_query_schedule), instead of (or in addition to) the
    one-shot google_bigquery_job gated by var.enable_content_classification.

    NOTE: a scheduled query with this exact purpose already exists in the
    live project, created manually outside Terraform:
    projects/YOUR_PROJECT_NUMBER/locations/us/transferConfigs/YOUR_TRANSFER_CONFIG_ID
    ("Gemini Ent - Daily Content Classification", schedule "every day 18:00"
    UTC). Setting this flag to true WITHOUT importing that existing config
    first will create a second, duplicate scheduled query that double-runs
    (and double-bills) the classification script. Either `terraform import`
    the existing transfer config into
    google_bigquery_data_transfer_config.daily_content_classification[0]
    before applying, or leave this false and keep managing the existing one
    manually.

    Requires the bigquerydatatransfer.googleapis.com API to be enabled on
    the project (this module enables it automatically via apis.tf).
  EOT
  type        = bool
  default     = false
}

variable "scheduled_query_schedule" {
  description = <<-EOT
    BigQuery Data Transfer Service schedule string for the daily content
    classification scheduled query (google_bigquery_data_transfer_config,
    scheduled_query.tf). Default "every day 18:00".

    IMPORTANT: BigQuery scheduled queries are evaluated in UTC — there is no
    timezone parameter on the API. "every day 18:00" = 18:00 UTC = 03:00 KST
    (the following day). Convert your desired local time to UTC yourself
    when changing this.
  EOT
  type        = string
  default     = "every day 18:00"
}

variable "scheduled_query_service_account" {
  description = <<-EOT
    Service account email the scheduled queries (archive.tf, scheduled_query.tf)
    run as.

    Empty string (default) means the project's DEFAULT COMPUTE ENGINE service
    account, resolved at plan time as
    "<project-number>-compute@developer.gserviceaccount.com" from
    data.google_project — not hardcoded, so this works in any project.

    Empty does NOT mean "let Data Transfer Service decide": DTS has no default
    runner, and creating a transfer config without one fails with
    "Error 400: Failed to find a valid credential. The field 'version_info' or
    'service_account_name' must be specified." See the header comment in
    scheduled_query.tf.

    Whoever runs terraform needs iam.serviceAccounts.actAs on this SA, and the
    SA needs BigQuery Data Editor on the datasets plus Vertex AI User for the
    Gemini calls in sql/02. Set this explicitly if the default compute SA does
    not exist (Compute Engine API never enabled) or lacks those roles.
  EOT
  type        = string
  default     = ""
}
