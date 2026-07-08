# =============================================================================
# API enablement — makes this module deployable against a brand-new/empty
# project with a single `terraform apply` ("one-shot deploy").
# =============================================================================
# Every other resource in this module depends (directly or transitively) on
# depends_on = [google_project_service.apis] so Terraform always enables APIs
# first, before touching BigQuery/Logging/Vertex AI/Data Transfer resources.
#
# disable_on_destroy = false: `terraform destroy` must NOT disable these APIs.
# Disabling bigquery.googleapis.com etc. on destroy is both slow and
# dangerous in a shared project (it can affect resources this module doesn't
# own) — enablement is a one-way ratchet here, matching how most real GCP
# projects treat API enablement.

resource "google_project_service" "apis" {
  for_each = toset([
    "bigquery.googleapis.com",             # BigQuery core (datasets, jobs, views)
    "bigqueryconnection.googleapis.com",   # BQ <-> Vertex AI CLOUD_RESOURCE connections
    "logging.googleapis.com",              # Cloud Logging + Log Analytics
    "aiplatform.googleapis.com",           # Vertex AI (Gemini endpoint called by the remote model)
    "bigquerydatatransfer.googleapis.com", # BigQuery Data Transfer Service (scheduled queries)
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
