# =============================================================================
# BigQuery datasets
# =============================================================================
# NOTE: gemini_ent_analytics (the Log Analytics linked dataset that owns
# _AllLogs) is NOT created here — it is a side effect of the
# google_logging_linked_dataset resource in logging.tf. BigQuery cannot own a
# linked dataset directly; see logging.tf for the full explanation.

resource "google_bigquery_dataset" "gemini_ent_dashboard" {
  project     = var.project_id
  dataset_id  = var.dashboard_dataset_id
  location    = var.bq_location
  description = "Gemini Enterprise + Model Armor dashboard: views (v_*), the content-classification table (t_content_topics), and the gemini_flash remote model."

  labels = {
    app   = "gemini-enterprise-dashboard"
    layer = "presentation"
  }

  # The upstream analytics dataset is forward-only and append-heavy; this
  # dataset only holds views + a small derived table, so accidental
  # `terraform destroy` risk is limited, but we still require an explicit
  # confirmation step outside Terraform before ever destroying it (see
  # terraform/README.md).
  delete_contents_on_destroy = false

  depends_on = [google_project_service.apis]
}
