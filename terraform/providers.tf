# =============================================================================
# Provider configuration
# =============================================================================
# Pinned to the latest stable major of the google provider available at the
# time this module was written. Bump the upper bound deliberately after
# reviewing the provider CHANGELOG — do not widen it blindly.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    # Used solely for time_sleep.wait_for_iam_propagation in
    # model_and_views.tf — IAM bindings on the BQ connection's service
    # account (roles/aiplatform.user) take several minutes to propagate
    # before Vertex AI actually honors them, and CREATE MODEL fails with a
    # permission error if run immediately after the binding. See that
    # resource's comment for the measured delay.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }

  # No remote backend is configured here on purpose: this module is meant to
  # be reviewed with `terraform plan` first. Add a `backend` block (GCS is
  # the natural choice on this project) before any real `terraform apply`.
}

provider "google" {
  project = var.project_id
  region  = var.region
}
