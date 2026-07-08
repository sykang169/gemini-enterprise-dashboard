# =============================================================================
# Outputs
# =============================================================================

output "dashboard_dataset_id" {
  description = "Fully-qualified id of the dashboard dataset (views + model live here)."
  value       = google_bigquery_dataset.gemini_ent_dashboard.id
}

output "analytics_linked_dataset_id" {
  description = "Fully-qualified id of the Log Analytics linked dataset (_AllLogs lives here)."
  value       = google_logging_linked_dataset.gemini_ent_analytics.id
}

output "bigquery_connection_id" {
  description = "Resource id of the CLOUD_RESOURCE connection used for Vertex AI calls."
  value       = google_bigquery_connection.gemini_conn.id
}

output "bigquery_connection_service_account" {
  description = "Service account created for the BQ connection; must retain roles/aiplatform.user for ML.GENERATE_TEXT calls to succeed."
  value       = google_bigquery_connection.gemini_conn.cloud_resource[0].service_account_id
}

output "remote_model_id" {
  description = "Fully-qualified id of the gemini_flash remote model."
  value       = "${var.project_id}.${var.dashboard_dataset_id}.${var.model_name}"
}

output "remote_model_endpoint" {
  description = "Vertex AI endpoint currently backing gemini_flash. See var.gemini_endpoint for verified-working vs. failing endpoint notes on this project."
  value       = var.gemini_endpoint
}

output "scheduled_classification_transfer_config_id" {
  description = "Resource id of the Terraform-managed daily content-classification scheduled query, if var.enable_scheduled_classification is true. NOTE: a manually-created equivalent (projects/YOUR_PROJECT_NUMBER/locations/us/transferConfigs/YOUR_TRANSFER_CONFIG_ID) already runs in the live project — see scheduled_query.tf before enabling this to avoid a duplicate schedule."
  value       = try(google_bigquery_data_transfer_config.daily_content_classification[0].id, null)
}

locals {
  view_names = [
    "v_daily_queries", "v_daily_queries_by_method", "v_daily_agent_calls",
    "v_queries_per_user", "v_daily_active_users", "v_daily_failure_rate",
    "v_streamassist_state", "v_model_armor_block", "v_model_armor_threats",
    "v_model_armor_threats_long", "v_hourly_heatmap", "v_agent_usage_daily",
    "v_response_latency_daily", "v_grounding_top_sources",
    "v_grounding_coverage_daily", "v_user_activity_detail",
    "v_model_armor_by_client", "v_user_agent_trace",
    "v_model_armor_verdict_daily",
  ]

  looker_studio_query_params = concat(
    ["c.mode=edit", "c.reportName=${urlencode("Gemini Enterprise 운영-보안 대시보드")}"],
    flatten([
      for v in local.view_names : [
        "ds.${v}.connector=bigQuery",
        "ds.${v}.type=TABLE",
        "ds.${v}.projectId=${var.project_id}",
        "ds.${v}.billingProjectId=${var.project_id}",
        "ds.${v}.datasetId=${var.dashboard_dataset_id}",
        "ds.${v}.tableId=${v}",
      ]
    ])
  )
}

output "views_created" {
  description = "List of dashboard views created by sql/01_create_views.sql (kept in sync manually with that script; update this list if you add/remove a view)."
  value       = local.view_names
}

output "looker_studio_create_url" {
  description = "Ready-to-open Looker Studio 'create report' deep link, with all 19 dashboard views pre-wired as BigQuery data sources. This is the URL deploy.sh prints after a successful apply."
  value       = "https://lookerstudio.google.com/reporting/create?${join("&", local.looker_studio_query_params)}"
}

output "looker_studio_create_url_hint" {
  description = "How to build a Looker Studio 'create report' deep link for these views by hand, if you ever need a different subset than looker_studio_create_url provides. Looker Studio reports themselves are not Terraform-managed."
  value       = "https://lookerstudio.google.com/reporting/create?c.mode=edit&c.reportName=<name>&ds.<alias>.connector=bigQuery&ds.<alias>.type=TABLE&ds.<alias>.projectId=${var.project_id}&ds.<alias>.billingProjectId=${var.project_id}&ds.<alias>.datasetId=${var.dashboard_dataset_id}&ds.<alias>.tableId=<view_name>  (repeat the ds.<alias>.* group per view, one alias per data source)"
}
