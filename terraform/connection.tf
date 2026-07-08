# =============================================================================
# BigQuery <-> Vertex AI (Gemini) connection
# =============================================================================
# CLOUD_RESOURCE connection used by BigQuery ML remote models (ML.GENERATE_TEXT
# against gemini_flash) to call Vertex AI. Location must be a single region or
# multi-region that BigQuery ML remote models support alongside the dataset
# location — using var.bq_location ("US") keeps everything in the same
# multi-region as gemini_ent_dashboard and gemini_ent_analytics.

resource "google_bigquery_connection" "gemini_conn" {
  project       = var.project_id
  connection_id = var.connection_id
  location      = var.bq_location
  friendly_name = "Gemini Enterprise dashboard -> Vertex AI"
  description   = "CLOUD_RESOURCE connection used by gemini_ent_dashboard.gemini_flash to call the Gemini endpoint from BigQuery ML."

  cloud_resource {}

  depends_on = [google_project_service.apis]
}

# The connection provisions its own service account
# (cloud_resource[0].service_account_id); that SA is what actually calls
# Vertex AI, so it needs Vertex AI User, not the Terraform caller's identity.
resource "google_project_iam_member" "gemini_conn_aiplatform_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_bigquery_connection.gemini_conn.cloud_resource[0].service_account_id}"
}
