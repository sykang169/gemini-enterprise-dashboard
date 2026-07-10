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
  description = "Service account email the scheduled query (google_bigquery_data_transfer_config) runs as. Empty string means BigQuery Data Transfer Service uses its own default credentials/behavior instead of impersonating a specific service account. The already-existing manual config in this project runs under the default Compute Engine service account."
  type        = string
  default     = ""
}
