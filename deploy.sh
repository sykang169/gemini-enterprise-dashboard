#!/usr/bin/env bash
# =============================================================================
# One-shot deploy wrapper for the Gemini Enterprise + Model Armor dashboard.
#
# Usage:
#   ./deploy.sh <PROJECT_ID> [extra terraform apply args...]
#   ./deploy.sh my-project -auto-approve          # unattended (recommended for retries)
#
# It is safe to re-run against a project that already has some/all of the
# dashboard resources — pre-existing datasets/connections/links are imported
# into Terraform state instead of failing with "409 Already Exists".
#
# What it does, in order:
#   0. Mint a static OAuth token so the google provider never touches the
#      (flaky) Cloud Shell metadata server.
#   1. Preflight: confirm auth + billing, then bootstrap the two APIs Terraform
#      itself needs (serviceusage, cloudresourcemanager).
#   2. terraform init.
#   3. Import any pre-existing dataset / connection / Log Analytics link.
#   4. terraform apply (with a small retry loop for eventual-consistency errors).
#   5. Print the Looker Studio "create report" URL.
#
# Resource names default to the module's variable defaults; override via the
# matching env vars below if you pass non-default -var values to Terraform.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/terraform"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <PROJECT_ID> [extra terraform apply args...]" >&2
  echo "Example: $0 my-gcp-project" >&2
  echo "Example (skip the interactive prompt): $0 my-gcp-project -auto-approve" >&2
  exit 1
fi

PROJECT_ID="$1"
shift
EXTRA_ARGS=("$@")

# Resource identifiers — keep in sync with terraform/variables.tf defaults.
# Override via env if you deploy with non-default -var values.
BQ_LOCATION="${BQ_LOCATION:-US}"
DASHBOARD_DATASET_ID="${DASHBOARD_DATASET_ID:-gemini_ent_dashboard}"
ANALYTICS_DATASET_ID="${ANALYTICS_DATASET_ID:-gemini_ent_analytics}"
CONNECTION_ID="${CONNECTION_ID:-gemini_conn}"
LOG_BUCKET="${LOG_BUCKET:-_Default}"

# ---------------------------------------------------------------------------
# 0. Static access token — dodge Cloud Shell metadata-server token flakiness.
#    In Cloud Shell / GCE the provider fetches an OAuth token from the metadata
#    server on every call. Terraform fires many concurrently and the metadata
#    server intermittently returns an empty body ->
#      "oauth2/google: invalid token JSON from metadata: EOF"
#    Handing the provider one static token up front sidesteps that entirely.
# ---------------------------------------------------------------------------
if ! command -v gcloud >/dev/null 2>&1; then
  echo "ERROR: gcloud not found on PATH. Run this in Cloud Shell or install the gcloud CLI." >&2
  exit 1
fi

if [[ -z "${GOOGLE_OAUTH_ACCESS_TOKEN:-}" ]]; then
  if _tok="$(gcloud auth print-access-token 2>/dev/null)" && [[ -n "${_tok}" ]]; then
    export GOOGLE_OAUTH_ACCESS_TOKEN="${_tok}"
    echo ">>> Using a static access token to avoid metadata-server flakiness (valid ~1h)."
  else
    echo "ERROR: no active gcloud credentials — 'gcloud auth print-access-token' failed." >&2
    echo "       Run 'gcloud auth login' (Cloud Shell may have dropped its session) and retry." >&2
    exit 1
  fi
  unset _tok
fi

# ---------------------------------------------------------------------------
# 1. Preflight — fail fast with actionable messages instead of deep in apply.
# ---------------------------------------------------------------------------
echo ">>> Preflight checks for project: ${PROJECT_ID}"

# 1a. Billing must be enabled (BigQuery + Log Analytics both require it).
billing_enabled="$(gcloud billing projects describe "${PROJECT_ID}" \
  --format="value(billingEnabled)" 2>/dev/null || echo "")"
if [[ "${billing_enabled}" != "True" ]]; then
  echo "ERROR: billing is not enabled on ${PROJECT_ID} (or you lack permission to read it)." >&2
  echo "       BigQuery and Log Analytics will fail with BILLING_DISABLED." >&2
  echo "       Link a billing account, then re-run:" >&2
  echo "         gcloud billing accounts list" >&2
  echo "         gcloud billing projects link ${PROJECT_ID} --billing-account=XXXXXX-XXXXXX-XXXXXX" >&2
  exit 1
fi
echo ">>> billing: enabled"

# 1b. Bootstrap the two APIs Terraform itself needs to enable everything else.
#     Without these, google_project_service fails with SERVICE_DISABLED on the
#     serviceusage endpoint (chicken-and-egg). Idempotent; ~instant if already on.
echo ">>> Ensuring serviceusage + cloudresourcemanager APIs are enabled..."
gcloud services enable serviceusage.googleapis.com cloudresourcemanager.googleapis.com \
  --project="${PROJECT_ID}"

# ---------------------------------------------------------------------------
# 2. terraform init
# ---------------------------------------------------------------------------
echo ">>> terraform -chdir=${TF_DIR} init"
terraform -chdir="${TF_DIR}" init

# ---------------------------------------------------------------------------
# 3. Import pre-existing resources so re-runs / partially-provisioned projects
#    don't die on "409 Already Exists". Each import is best-effort: skipped if
#    already in state, ignored if the resource doesn't exist yet in the project.
# ---------------------------------------------------------------------------
import_if_missing() {
  local addr="$1" id="$2"
  if terraform -chdir="${TF_DIR}" state list 2>/dev/null | grep -qx "${addr}"; then
    return 0  # already tracked
  fi
  echo ">>> import (if it exists): ${addr}"
  terraform -chdir="${TF_DIR}" import -var="project_id=${PROJECT_ID}" "${addr}" "${id}" \
    >/dev/null 2>&1 || true
}

echo ">>> Importing any pre-existing dashboard resources..."
import_if_missing "google_bigquery_dataset.gemini_ent_dashboard" \
  "projects/${PROJECT_ID}/datasets/${DASHBOARD_DATASET_ID}"
import_if_missing "google_bigquery_connection.gemini_conn" \
  "projects/${PROJECT_ID}/locations/${BQ_LOCATION,,}/connections/${CONNECTION_ID}"
import_if_missing "google_logging_linked_dataset.gemini_ent_analytics" \
  "projects/${PROJECT_ID}/locations/global/buckets/${LOG_BUCKET}/links/${ANALYTICS_DATASET_ID}"

# ---------------------------------------------------------------------------
# 4. terraform apply, with a short retry loop.
#    Some steps fail transiently on first try and succeed on retry:
#      - the BQ connection's service account ("bqcx-...condel") is eventually
#        consistent, so the roles/aiplatform.user binding can 400 with
#        "Service account ... does not exist" until it propagates;
#      - freshly-enabled APIs can briefly still report SERVICE_DISABLED.
#    Pass -auto-approve for the retries to run unattended.
# ---------------------------------------------------------------------------
echo ">>> terraform apply -var=\"project_id=${PROJECT_ID}\" ${EXTRA_ARGS[*]}"
echo ">>> NOTE: includes a 300s (5 min) wait for IAM propagation before the"
echo ">>>       remote model is created — expect ~7 minutes total for a fresh project."

attempt=1
max_attempts=3
until terraform -chdir="${TF_DIR}" apply -var="project_id=${PROJECT_ID}" "${EXTRA_ARGS[@]}"; do
  if (( attempt >= max_attempts )); then
    echo "ERROR: terraform apply still failing after ${max_attempts} attempts." >&2
    exit 1
  fi
  echo ">>> apply failed (attempt ${attempt}/${max_attempts}) — likely a transient" >&2
  echo ">>> propagation/eventual-consistency error. Waiting 30s and retrying..." >&2
  sleep 30
  attempt=$(( attempt + 1 ))
done

# ---------------------------------------------------------------------------
# 5. Report the Looker Studio dashboard.
#    Looker Studio has no API to create charts from scratch, so a fully-built
#    dashboard is produced by cloning a TEMPLATE report (set once via
#    -var="looker_studio_template_report_id=..."). When a template is set the
#    output is a clone URL; otherwise it's manual setup instructions.
#
#    The clone URL wires all ~19 views and is ~6 KB long — printed to a wrapping
#    terminal and copied, it truncates ("Missing value for ds.<view>.datasetId").
#    So write it to a file as ONE unbroken line and copy it from there.
# ---------------------------------------------------------------------------
LS_OUTPUT="$(terraform -chdir="${TF_DIR}" output -raw looker_studio_url)"

echo
echo ">>> Deploy complete. BigQuery views are ready in ${PROJECT_ID}.${DASHBOARD_DATASET_ID}."
echo
if [[ "${LS_OUTPUT}" == http* ]]; then
  URL_FILE="${SCRIPT_DIR}/looker_studio_create_url.txt"
  printf '%s' "${LS_OUTPUT}" > "${URL_FILE}"
  echo ">>> Looker Studio dashboard clone URL written to:"
  echo ">>>   ${URL_FILE}   ($(wc -c < "${URL_FILE}") chars)"
  echo ">>> Open it as a SINGLE line (do NOT copy wrapped terminal text — it truncates)."
  echo ">>> In Cloud Shell:  cloudshell edit ${URL_FILE}   # Ctrl+A, Ctrl+C, paste in browser"
else
  echo "${LS_OUTPUT}"
fi
