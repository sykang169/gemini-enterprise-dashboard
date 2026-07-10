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

  # Template-clone deep link. Looker Studio has no API to create charts, so a
  # fully-built dashboard is produced by cloning a TEMPLATE report (built once,
  # see var.looker_studio_template_report_id) and repointing its BigQuery data
  # sources at THIS project.
  #
  # We use the ds.* WILDCARD and OMIT ds.*.connector on purpose. Per the Linking
  # API spec, omitting the connector makes it UPDATE only the given params
  # (projectId / billingProjectId / datasetId) rather than REPLACE the whole
  # data source — so each source keeps its template tableId (= its view) and all
  # the charts built on it. Since the template's dataset name and view names are
  # identical across projects, repointing just the project is enough.
  #
  # Two big wins over listing every view: the URL stays tiny (no 19x6 param
  # explosion → no copy-truncation), and the template's data-source ALIASES no
  # longer have to match the view names (the wildcard hits them all).
  #
  # Also note r.reportName (NOT c.reportName — using c.reportName is one reason
  # the old from-scratch URL misbehaved).
  looker_studio_clone_params = [
    "c.reportId=${var.looker_studio_template_report_id}",
    "c.mode=edit",
    "r.reportName=${urlencode("Gemini Enterprise 운영·보안 대시보드 - ${var.project_id}")}",
    "ds.*.projectId=${var.project_id}",
    "ds.*.billingProjectId=${var.project_id}",
    "ds.*.datasetId=${var.dashboard_dataset_id}",
  ]

  looker_studio_manual_steps = <<-EOT
    Looker Studio 리포트 수동 생성 (템플릿 미설정 상태):
      1) https://lookerstudio.google.com → 빈 보고서 만들기
      2) 데이터 추가 → BigQuery → ${var.project_id} → ${var.dashboard_dataset_id}
      3) 아래 ${length(local.view_names)}개 뷰를 데이터 소스로 추가하고 차트 배치:
         ${join(", ", local.view_names)}
      4) 상세 차트 구성: looker_studio_setup.md (섹션 A를 첫 페이지로 권장)

    ▶ 이후 완전 자동 생성: 위에서 만든 리포트를 템플릿으로 등록하세요.
      모든 데이터 소스가 ${var.dashboard_dataset_id} 뷰이기만 하면 됩니다(별칭 불문 —
      복제 URL은 ds.* 와일드카드로 프로젝트만 갈아끼움). report id를 복사 →
      -var="looker_studio_template_report_id=<REPORT_ID>" 로 다시 apply 하면
      terraform output looker_studio_url 이 완성형 대시보드 복제 URL을 뽑아줍니다.
  EOT
}

output "views_created" {
  description = "List of dashboard views created by sql/01_create_views.sql (kept in sync manually with that script; update this list if you add/remove a view)."
  value       = local.view_names
}

output "looker_studio_url" {
  description = <<-EOT
    Auto-generated Looker Studio deep link that clones the template report
    (var.looker_studio_template_report_id) into a fully-built dashboard for this
    project, with every BigQuery data source repointed to this project's views.
    If no template id is set, this returns manual setup instructions instead
    (Looker Studio cannot create charts without a pre-existing template).
  EOT
  value = var.looker_studio_template_report_id == "" ? local.looker_studio_manual_steps : (
    "https://lookerstudio.google.com/reporting/create?${join("&", local.looker_studio_clone_params)}"
  )
}
