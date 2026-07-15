# Gemini Enterprise + Model Armor Dashboard — Terraform

Infrastructure-as-code for the BigQuery/Looker Studio dashboard that was
originally built by hand. Designed as a **one-shot deploy**: against a
brand-new/empty GCP project, `terraform apply -var="project_id=<PROJECT>"`
(or `../deploy.sh <PROJECT>`) enables every required API, builds every
resource, and finishes with a working Looker Studio create-URL — no manual
steps in between.

## Quickstart

```bash
git clone <this-repo> && cd dev-geminienterprise-dashboard
./deploy.sh <YOUR_PROJECT_ID>
# open the Looker Studio URL printed at the end
```

That's it — see "Prerequisites" below for the IAM/billing you need on
`<YOUR_PROJECT_ID>` first. Expect **~7 minutes** (most of it a mandatory
5-minute IAM-propagation wait baked into the plan, see `model_and_views.tf`).

**Deploying to a different project than `YOUR_PROJECT_ID`**: just
set `project_id` — the project id (and dataset ids) hardcoded inside
`sql/01_create_views.sql` / `sql/02_content_classification.sql` are
automatically rewritten to `var.project_id` / `var.analytics_dataset_id` /
`var.dashboard_dataset_id` via `replace()` in `model_and_views.tf` before
Terraform sends the SQL to BigQuery, so no manual SQL edits are needed.

**Open in Cloud Shell** (no local `terraform`/`gcloud` install needed): once
this repo has a public git URL, use
`https://ssh.cloud.google.com/cloudshell/editor?cloudshell_git_repo=<REPO_URL>&cloudshell_workspace=.&cloudshell_tutorial=AUTOMATION.md`
— replace `<REPO_URL>` with this repo's clone URL. Cloud Shell opens with the
repo checked out, `gcloud`/`terraform` preinstalled and already authenticated
as you; run the Quickstart commands above from its terminal.

| File | Resource(s) | Purpose |
|---|---|---|
| `providers.tf` | `terraform{}`, `provider "google"`, `provider "time"` | Provider pins (google `~> 6.0`, time `~> 0.11`), project/region wiring |
| `apis.tf` | `google_project_service.apis` (for_each, 6 APIs) | Enables every API this module needs, so a brand-new project works with zero manual `gcloud services enable` steps |
| `variables.tf` | — | All configurable names (project, dataset ids, connection id, model name/endpoint, flags, schedule) — everything but `project_id` has a working default |
| `backend.tf` | `terraform { backend "gcs" {} }` | Remote state in GCS. The block is empty because backends cannot use variables; `deploy.sh` supplies bucket/prefix at `init` and creates the bucket first. Without this, deploying the same project from a second machine dies on `Already Exists: Job ...` — BigQuery job ids are a sha256 of their SQL and are unique per project forever |
| `datasets.tf` | `google_bigquery_dataset.gemini_ent_dashboard` | The dashboard-facing dataset that holds the views |
| `sensitive_logging.tf` | `null_resource.enable_sensitive_logging` (opt-in) | PATCHes `observabilityConfig` on the Gemini Enterprise engines so prompts/responses/user ids are logged in the clear instead of `<elided>`. Forward-only — nothing is backfilled |
| `archive.tf` | `google_bigquery_job.archive_logs` (opt-in), `google_bigquery_data_transfer_config.daily_log_archive` (opt-in) | Creates + backfills `t_logs_archive`, then keeps it current hourly. `_AllLogs` is a view over the log bucket, so the bucket's retention is the hard limit on history without this |
| `logging.tf` | `null_resource.enable_log_analytics`, `google_logging_linked_dataset.gemini_ent_analytics` | Enables Log Analytics on the `_Default` log bucket, links it into BigQuery as `gemini_ent_analytics._AllLogs` |
| `connection.tf` | `google_bigquery_connection.gemini_conn`, `google_project_iam_member.gemini_conn_aiplatform_user` | `us.gemini_conn` CLOUD_RESOURCE connection + `roles/aiplatform.user` on its service account |
| `model_and_views.tf` | `time_sleep.wait_for_iam_propagation`, `google_bigquery_job.create_model_gemini_flash`, `google_bigquery_job.create_dashboard_views`, `google_bigquery_job.run_content_classification` (opt-in) | Waits for IAM to propagate, then runs the `CREATE MODEL` DDL, then `sql/01_create_views.sql`, and optionally `sql/02_content_classification.sql`. Also renders `DASHBOARD_WINDOW_DAYS` into `v_log_source` from `var.dashboard_window_days` |
| `scheduled_query.tf` | `google_bigquery_data_transfer_config.daily_content_classification` (opt-in) | Recurring scheduled query (default `every day 18:00` UTC) that re-runs `sql/02_content_classification.sql`, as an alternative to the one-shot job above |
| `outputs.tf` | — | Dataset/connection ids, connection service account, remote model endpoint, scheduled-query id, ready-to-open Looker Studio create URL |
| `terraform.tfvars.example` | — | Copy to `terraform.tfvars`; only `project_id` needs filling in |

Resource count: **14 resource blocks** (19 actual resource instances,
counting the 6 API instances under `google_project_service.apis`'s
`for_each`): 1 API-enablement block (5 instances), 1 dataset, 1
null_resource, 1 linked dataset, 1 connection, 1 IAM member, 1 time_sleep, 2
always-on `bigquery_job`, 1 opt-in `bigquery_job` via `count`, 1 opt-in
`bigquery_data_transfer_config` via `count`.

## Prerequisites

**On the target GCP project**
- Billing enabled (BigQuery, Vertex AI, and Log Analytics all require it)
- The principal running `terraform apply` needs **Owner** or **Editor**,
  or (narrower) all of:
  - `roles/bigquery.admin` — create datasets, run `CREATE MODEL`/view jobs
  - `roles/logging.admin` — enable Log Analytics + create the linked dataset
  - `roles/resourcemanager.projectIamAdmin` (or narrower: ability to grant
    `roles/aiplatform.user`) — grant the connection's service account access
    to Vertex AI
  - `roles/serviceusage.serviceUsageAdmin` — this module now enables its own
    APIs via `apis.tf` (`google_project_service`), so the applying principal
    needs permission to *enable* services, not just consume them

**Terraform / tooling**
- Terraform >= 1.5, google provider `~> 6.0`, time provider `~> 0.11` (see
  `providers.tf`) — `terraform init` downloads both automatically
- `gcloud` CLI authenticated as the same principal `terraform apply` runs as
  (needed for the `local-exec` step in `logging.tf`)

Nothing else needs to pre-exist: `apis.tf` enables
`bigquery.googleapis.com`, `bigqueryconnection.googleapis.com`,
`logging.googleapis.com`, `aiplatform.googleapis.com`, and
`bigquerydatatransfer.googleapis.com` itself as the very first step of every
apply (everything else `depends_on` it).

## Usage

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # then edit project_id
terraform init
terraform plan
terraform apply
```

or, without a tfvars file:

```bash
cd terraform
terraform init
terraform plan   -var="project_id=<YOUR_PROJECT_ID>"
terraform apply  -var="project_id=<YOUR_PROJECT_ID>"
```

or the one-line wrapper from the repo root: `./deploy.sh <YOUR_PROJECT_ID>`.

All variables besides `project_id` have defaults matching the current
manually-built environment (see `variables.tf`), so further `-var` overrides
are only needed if you're targeting different dataset naming, a different
Gemini endpoint, or a different scheduled-query time.

To (re)run the optional, cost-incurring content-classification batch:

```bash
terraform apply -var="enable_content_classification=true"
# subsequent re-runs of the SAME classification pass require an explicit -replace,
# because job_id is intentionally excluded from routine change detection:
terraform apply -var="enable_content_classification=true" \
  -replace="google_bigquery_job.run_content_classification[0]"
```

To manage the **recurring** (daily) classification scheduled query instead of
the one-shot job, see the "scheduled query" limitation below **before**
enabling `var.enable_scheduled_classification` — a manually-created
equivalent already runs in the live project and enabling the flag without
importing it first creates a duplicate:

```bash
# Recommended: import the existing manual config instead of creating a new one
terraform import 'google_bigquery_data_transfer_config.daily_content_classification[0]' \
  projects/YOUR_PROJECT_NUMBER/locations/us/transferConfigs/YOUR_TRANSFER_CONFIG_ID \
  -var="enable_scheduled_classification=true"
terraform plan -var="enable_scheduled_classification=true"   # review diff before applying
```

The schedule itself is `var.scheduled_query_schedule` (default `"every day
18:00"`). BigQuery Data Transfer Service schedules are always evaluated in
**UTC** — there is no timezone parameter — so `18:00` means 18:00 UTC =
03:00 KST the next day. The live manual config was updated from `every 24
hours` to this same `every day 18:00` (UTC) schedule; override the variable
if you want a different fixed daily time, converting to UTC yourself.

## Known limitations / read before applying

- **Log Analytics enablement is not native Terraform state.** `logging.tf`
  uses `null_resource` + `local-exec` (`gcloud logging buckets update
  --enable-analytics`) instead of `google_logging_project_bucket_config`,
  because `_Default` is a pre-existing singleton bucket and managing it as a
  full resource would put its retention/lock/CMEK settings under Terraform's
  authority too — see the long comment at the top of `logging.tf` for the
  native-resource alternative and its risks. The commented-out example in
  that file uses `retention_days = 90` to match the bucket's **current**
  retention (was 30 days at initial authoring time, now 90 — always check
  `gcloud logging buckets describe _Default --location=global` for the live
  value before ever managing this bucket as a full resource).
- **Forward-only indexing.** Log Analytics only indexes logs ingested *after*
  it was enabled on the bucket. Re-running `terraform apply` does not
  backfill history; there is no Terraform-manageable way around this — it's
  an upstream Cloud Logging constraint.
- **IAM propagation wait (~5 min) is real and required.** `model_and_views.tf`
  inserts `time_sleep.wait_for_iam_propagation` (300s) between granting
  `roles/aiplatform.user` on the connection's service account and running
  `CREATE MODEL`. This was measured directly on this project: applying the
  model-creation job immediately after the IAM grant fails with a
  permission-denied error. If you see that error anyway, the propagation
  delay on your project may exceed 5 minutes — rerun `terraform apply` (the
  job is idempotent) or increase `create_duration` in that resource.
- **API enablement is automatic, but also a one-way ratchet.**
  `google_project_service.apis` sets `disable_on_destroy = false`, so
  `terraform destroy` never disables APIs it enabled — re-disabling shared
  APIs in a project Terraform doesn't fully own is out of scope for this
  module.
- **BigQuery jobs are immutable.** `google_bigquery_job` resources are keyed
  by a hash of their SQL text (`job_id`) precisely so that editing
  `sql/01_create_views.sql` produces a new job (and thus actually re-runs the
  script) while an unchanged file produces zero plan diff.
- **Cost / model endpoint:** the remote model uses `var.gemini_endpoint`,
  default `gemini-2.5-flash-lite` (cheapest verified-working option — see
  below). `google_bigquery_job.run_content_classification` and
  `google_bigquery_data_transfer_config.daily_content_classification` both
  call this endpoint once per not-yet-classified log row. Both are gated off
  by default (`var.enable_content_classification` /
  `var.enable_scheduled_classification` = `false`) — leave them off for
  routine infra applies.
- **Endpoint compatibility (verified on this project):** `gemini-2.0-flash`,
  `gemini-2.0-flash-lite`, and `gemini-2.0-flash-001` all fail with "not
  found" against `YOUR_PROJECT_ID`'s remote-model connection. Only
  `gemini-2.5-flash-lite` and `gemini-2.5-flash` are confirmed working. Don't
  set `var.gemini_endpoint` back to a `gemini-2.0-*` value without
  re-verifying against the live connection.
- **Scheduled query duplication risk:** a scheduled query with the exact same
  purpose (`Gemini Ent - Daily Content Classification`, `every day 18:00` UTC)
  already exists in the live project
  (`projects/YOUR_PROJECT_NUMBER/locations/us/transferConfigs/YOUR_TRANSFER_CONFIG_ID`),
  created manually. Enabling `var.enable_scheduled_classification` without
  importing that config first creates a second, duplicate schedule that
  double-runs and double-bills the classification query — see the `terraform
  import` command above.
- **`t_content_topics` does not self-refresh.** Unlike the `v_*` views (live
  `SELECT`s, always current), the content-classification table is populated
  by explicitly re-running `sql/02_content_classification.sql`. Use either
  the one-shot `google_bigquery_job.run_content_classification` (per-apply)
  or the recurring `google_bigquery_data_transfer_config` in
  `scheduled_query.tf` (daily) — without one of these running periodically,
  the table (and the `v_topic_distribution` / `v_intent_distribution` /
  `v_sentiment_daily` views built on it) goes stale as new logs arrive.
- **No `terraform destroy` safety net for the linked dataset.** Log Analytics
  cannot be disabled once enabled (an upstream limitation, not a Terraform
  one); destroying `google_logging_linked_dataset.gemini_ent_analytics` only
  removes the BigQuery-side link, not the underlying analytics setting.
- This module was validated with `terraform fmt -check` only (see repo root
  `AUTOMATION.md`); `terraform init`/`plan`/`apply` were intentionally **not**
  run while authoring it — run them yourself after reviewing the plan.
