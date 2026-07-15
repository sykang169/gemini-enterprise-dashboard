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
#
#    This ALSO authenticates the GCS state backend (step 2). The backend does
#    not share the provider's credentials — without this variable it falls back
#    to Application Default Credentials and `terraform init` can die on
#    `oauth2: "invalid_grant" "reauth related error (invalid_rapt)"` even though
#    gcloud itself is perfectly happy. Keep this export BEFORE init.
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

# 1b. Bootstrap the APIs Terraform itself needs to enable everything else.
#     Without these, google_project_service fails with SERVICE_DISABLED on the
#     serviceusage endpoint (chicken-and-egg). storage is here rather than in
#     apis.tf for the same reason: the state bucket must exist before Terraform
#     runs at all, so Terraform cannot be what enables the API that creates it.
#     Idempotent; ~instant if already on.
echo ">>> Ensuring serviceusage + cloudresourcemanager + storage APIs are enabled..."
gcloud services enable serviceusage.googleapis.com cloudresourcemanager.googleapis.com \
  storage.googleapis.com --project="${PROJECT_ID}"

# ---------------------------------------------------------------------------
# 2. Remote state bucket + terraform init.
# ---------------------------------------------------------------------------
# State lives in GCS, not on this machine, so that deploying the same project
# from a different PC applies only what changed instead of trying to recreate
# everything (and dying on "Already Exists" for the BigQuery jobs, whose ids
# are a sha256 of their SQL and are unique per project forever). See
# terraform/backend.tf.
#
# Terraform can't create the bucket holding its own state, so it is created
# here, before init. Versioning is on deliberately: state is the one file whose
# loss means re-importing every resource by hand.
STATE_BUCKET="${STATE_BUCKET:-${PROJECT_ID}-tfstate}"
STATE_PREFIX="${STATE_PREFIX:-gemini-ent-dashboard}"

if gcloud storage buckets describe "gs://${STATE_BUCKET}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo ">>> Terraform state bucket: gs://${STATE_BUCKET} (exists)"
else
  echo ">>> Creating Terraform state bucket gs://${STATE_BUCKET} ..."
  # --uniform-bucket-level-access: state is not per-object ACL material.
  # --public-access-prevention: state can embed resource metadata; never public.
  if ! gcloud storage buckets create "gs://${STATE_BUCKET}" \
       --project="${PROJECT_ID}" \
       --location="${BQ_LOCATION}" \
       --uniform-bucket-level-access \
       --public-access-prevention 2>&1; then
    echo "ERROR: could not create the state bucket gs://${STATE_BUCKET}." >&2
    echo "       GCS bucket names are GLOBALLY unique — if the name is taken by" >&2
    echo "       another organization, pick your own and re-run:" >&2
    echo "         STATE_BUCKET=my-unique-tfstate $0 ${PROJECT_ID}" >&2
    exit 1
  fi
  gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning --project="${PROJECT_ID}"
fi

echo ">>> terraform -chdir=${TF_DIR} init (backend: gs://${STATE_BUCKET}/${STATE_PREFIX})"
# -reconfigure keeps init non-interactive when the backend settings are already
# recorded. It does NOT migrate a pre-existing LOCAL state — that is a one-time
# manual step, on purpose, because silently discarding a local state would lose
# the only record of the BigQuery jobs and strand the next deploy on a 409:
#   terraform -chdir=terraform init -migrate-state \
#     -backend-config="bucket=${STATE_BUCKET}" -backend-config="prefix=${STATE_PREFIX}"
if [[ -f "${TF_DIR}/terraform.tfstate" ]]; then
  echo ">>> WARNING: a local terraform.tfstate exists in ${TF_DIR}." >&2
  echo ">>>          It is NOT migrated automatically. If it describes this" >&2
  echo ">>>          project, migrate it once before deploying again:" >&2
  echo ">>>            terraform -chdir=terraform init -migrate-state \\" >&2
  echo ">>>              -backend-config=\"bucket=${STATE_BUCKET}\" \\" >&2
  echo ">>>              -backend-config=\"prefix=${STATE_PREFIX}\"" >&2
fi
terraform -chdir="${TF_DIR}" init -reconfigure \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="prefix=${STATE_PREFIX}"

# ---------------------------------------------------------------------------
# 3. Import pre-existing resources so re-runs / partially-provisioned projects
#    don't die on "409 Already Exists". Each import is best-effort: skipped if
#    already in state, ignored if the resource doesn't exist yet in the project.
#
#    BigQuery jobs are here for a nastier reason than the rest: BigQuery burns a
#    job ID permanently the moment it is used, even for a job that SUCCEEDED.
#    job_id is a sha256 of the SQL (see the locals in model_and_views.tf), so if
#    state is ever lost or rebuilt while the SQL is unchanged, Terraform
#    recomputes the same ID, tries to create it, and every apply from then on
#    dies with "409 Already Exists: Job ..., duplicate". That is NOT transient —
#    the retry loop in step 4 cannot fix it, it just repeats it. Re-adopting the
#    finished job is the only way out.
#
#    Verified 2026-07-15: create_model_gemini_flash_8973b4f855 had succeeded on
#    2026-07-10 and the model existed, but was absent from state, so apply 409'd
#    on every attempt until imported.
#
#    run_content_classification is deliberately not imported below: its job_id
#    is timestamp()-based, so it is unique per apply and can never collide.
# ---------------------------------------------------------------------------

# `terraform import` and `terraform console` must see the SAME variables as the
# apply, or they disagree with it about what exists: a resource gated by
# `count = var.enable_* ? 1 : 0` is absent from the config — and therefore
# un-importable — unless that flag is set, and the flags arrive in EXTRA_ARGS.
# Passing EXTRA_ARGS wholesale does not work: it also carries -auto-approve,
# which import/console reject. So forward only the -var bits. (Only the
# -var="k=v" / -var-file="f" forms are matched, which is what this script's
# usage documents; the space-separated `-var k=v` form is not.)
TF_VAR_ARGS=()
for _arg in ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}; do
  case "${_arg}" in
    -var=*|-var-file=*) TF_VAR_ARGS+=("${_arg}") ;;
  esac
done

import_if_missing() {
  local addr="$1" id="$2"
  if terraform -chdir="${TF_DIR}" state list 2>/dev/null | grep -qx "${addr}"; then
    return 0  # already tracked
  fi
  echo ">>> import (if it exists): ${addr}"
  terraform -chdir="${TF_DIR}" import -var="project_id=${PROJECT_ID}" \
    ${TF_VAR_ARGS[@]+"${TF_VAR_ARGS[@]}"} "${addr}" "${id}" \
    >/dev/null 2>&1 || true
}

job_id_of() {
  # Ask terraform for the resource's own job_id rather than re-deriving the
  # sha256 here — two implementations of one ID would drift, and the import
  # would then silently adopt the wrong job.
  terraform -chdir="${TF_DIR}" console -var="project_id=${PROJECT_ID}" \
    ${TF_VAR_ARGS[@]+"${TF_VAR_ARGS[@]}"} <<<"$1" 2>/dev/null \
    | tail -n1 | tr -d '"'
}

import_job_if_missing() {
  local addr="$1" expr="$2" jid
  jid="$(job_id_of "${expr}")"
  # An unresolved expression comes back as "(known after apply)" or empty;
  # importing that would be nonsense, so skip rather than guess.
  if [[ -z "${jid}" || "${jid}" == *"("* ]]; then
    echo ">>> WARNING: could not resolve job_id for ${addr} — skipping its import." >&2
    echo ">>>          If apply then fails with 409 Already Exists, import it by hand:" >&2
    echo ">>>            terraform -chdir=${TF_DIR} import ${addr} \\" >&2
    echo ">>>              projects/${PROJECT_ID}/jobs/<JOB_ID>/location/${BQ_LOCATION}" >&2
    return 0
  fi
  import_if_missing "${addr}" "projects/${PROJECT_ID}/jobs/${jid}/location/${BQ_LOCATION}"
}

echo ">>> Importing any pre-existing dashboard resources..."
import_if_missing "google_bigquery_dataset.gemini_ent_dashboard" \
  "projects/${PROJECT_ID}/datasets/${DASHBOARD_DATASET_ID}"
import_if_missing "google_bigquery_connection.gemini_conn" \
  "projects/${PROJECT_ID}/locations/${BQ_LOCATION,,}/connections/${CONNECTION_ID}"
import_if_missing "google_logging_linked_dataset.gemini_ent_analytics" \
  "projects/${PROJECT_ID}/locations/global/buckets/${LOG_BUCKET}/links/${ANALYTICS_DATASET_ID}"
import_job_if_missing "google_bigquery_job.create_model_gemini_flash" "local.create_model_job_id"
import_job_if_missing "google_bigquery_job.create_dashboard_views" "local.create_views_job_id"
# count-gated: the [0] address only exists when -var="enable_log_archive=true"
# is passed, which TF_VAR_ARGS forwards. Without it the import is a harmless
# no-op, like every other entry here.
import_job_if_missing "google_bigquery_job.archive_logs[0]" "local.archive_logs_job_id"

# ---------------------------------------------------------------------------
# 4. terraform apply, with a short retry loop.
#    Some steps fail transiently on first try and succeed on retry:
#      - the BQ connection's service account ("bqcx-...condel") is eventually
#        consistent, so the roles/aiplatform.user binding can 400 with
#        "Service account ... does not exist" until it propagates;
#      - freshly-enabled APIs can briefly still report SERVICE_DISABLED.
#    Pass -auto-approve for the retries to run unattended.
#
#    RETRY ONLY WHAT CAN ACTUALLY SUCCEED ON A RETRY. This loop used to call
#    every failure "likely a transient propagation error" and sleep 30s three
#    times. Deterministic failures — a burned job ID, a missing credential, a
#    denied permission — reproduce identically on every attempt, so the loop
#    turned a clear one-line error into a 90-second wait that buried the real
#    cause under two rounds of misleading "likely transient" text. Observed
#    2026-07-15 with a 409 duplicate job and a 400 missing credential, neither
#    of which any amount of retrying could fix.
#
#    So: capture the output, and bail immediately when it carries a signature
#    that retrying cannot change. Anything unrecognized is still treated as
#    transient and retried — the old behavior is the fallback, not the default.
# ---------------------------------------------------------------------------
echo ">>> terraform apply -var=\"project_id=${PROJECT_ID}\" ${EXTRA_ARGS[*]}"
echo ">>> NOTE: includes a 300s (5 min) wait for IAM propagation before the"
echo ">>>       remote model is created — expect ~7 minutes total for a fresh project."

# Signatures that are pointless to retry, and what to do about each.
is_permanent_failure() {
  local out="$1"
  if grep -q "Already Exists: Job" <<<"${out}"; then
    echo ">>> This is a BURNED JOB ID, not a transient error. BigQuery keeps a job" >&2
    echo ">>> id forever once used, so a job that already ran cannot be created" >&2
    echo ">>> again — retrying will fail identically every time. Terraform lost" >&2
    echo ">>> track of a job it previously created; re-adopt it:" >&2
    echo ">>>   terraform -chdir=${TF_DIR} import <ADDRESS> \\" >&2
    echo ">>>     projects/${PROJECT_ID}/jobs/<JOB_ID>/location/${BQ_LOCATION}" >&2
    echo ">>> Step 3 of this script does that automatically; if you are seeing" >&2
    echo ">>> this, its import was skipped — check the WARNING above." >&2
    return 0
  fi
  if grep -q "The field 'version_info' or 'service_account_name' must be specified" <<<"${out}"; then
    echo ">>> The scheduled query has no runner. BigQuery Data Transfer Service" >&2
    echo ">>> needs either a service account or an OAuth refresh token, and this" >&2
    echo ">>> script authenticates with a bare access token that has no refresh" >&2
    echo ">>> token — so a service account is the only option here. It defaults to" >&2
    echo ">>> the project's default Compute Engine SA; if that does not exist," >&2
    echo ">>> name one explicitly:" >&2
    echo ">>>   $0 ${PROJECT_ID} -var=\"scheduled_query_service_account=SA@${PROJECT_ID}.iam.gserviceaccount.com\"" >&2
    return 0
  fi
  if grep -q "iam.serviceAccounts.actAs" <<<"${out}"; then
    echo ">>> You lack actAs on the service account the scheduled query runs as." >&2
    echo ">>> Retrying cannot grant it. Fix with:" >&2
    echo ">>>   gcloud iam service-accounts add-iam-policy-binding \\" >&2
    echo ">>>     \"\$(terraform -chdir=${TF_DIR} output -raw scheduled_query_service_account)\" \\" >&2
    echo ">>>     --member=\"user:\$(gcloud config get-value account)\" \\" >&2
    echo ">>>     --role=\"roles/iam.serviceAccountUser\"" >&2
    return 0
  fi
  return 1
}

attempt=1
max_attempts=3
while true; do
  # Tee so the user still watches it live; the copy is only for classification.
  apply_out="$(mktemp)"
  if terraform -chdir="${TF_DIR}" apply -var="project_id=${PROJECT_ID}" \
       ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} 2>&1 | tee "${apply_out}"; then
    rm -f "${apply_out}"
    break
  fi
  out="$(cat "${apply_out}")"; rm -f "${apply_out}"

  if is_permanent_failure "${out}"; then
    echo "ERROR: terraform apply hit an error that retrying cannot fix (see above)." >&2
    exit 1
  fi
  if (( attempt >= max_attempts )); then
    echo "ERROR: terraform apply still failing after ${max_attempts} attempts." >&2
    exit 1
  fi
  echo ">>> apply failed (attempt ${attempt}/${max_attempts}) — no known-permanent" >&2
  echo ">>> signature, so this may be a transient propagation/eventual-consistency" >&2
  echo ">>> error. Waiting 30s and retrying..." >&2
  sleep 30
  attempt=$(( attempt + 1 ))
done

# ---------------------------------------------------------------------------
# 5. Report the Looker Studio dashboard.
#    Looker Studio has no API to create charts from scratch, so a fully-built
#    dashboard is produced by cloning a TEMPLATE report (set once via
#    -var="looker_studio_template_report_id=..."). When a template is set the
#    output is a short ds.* wildcard clone URL; otherwise it's manual setup
#    instructions.
# ---------------------------------------------------------------------------
LS_OUTPUT="$(terraform -chdir="${TF_DIR}" output -raw looker_studio_url)"

echo
echo ">>> Deploy complete. BigQuery views are ready in ${PROJECT_ID}.${DASHBOARD_DATASET_ID}."
echo
if [[ "${LS_OUTPUT}" == http* ]]; then
  printf '%s\n' "${LS_OUTPUT}" > "${SCRIPT_DIR}/looker_studio_create_url.txt"
  echo ">>> Looker Studio 완성형 대시보드 복제 URL (템플릿 → 이 프로젝트):"
  echo
  echo "${LS_OUTPUT}"
  echo
  echo ">>> 위 URL을 브라우저에 열면 대시보드가 복제됩니다. (사본: looker_studio_create_url.txt)"
else
  echo "${LS_OUTPUT}"
fi
