# =============================================================================
# OPT-IN: sensitive logging (prompt/response text + real user identity)
# =============================================================================
#
# WHAT THIS CONTROLS
# ------------------
# A Gemini Enterprise engine writes user-activity logs as soon as
# observability is on, but by default every *sensitive* field in them is
# replaced with the 8-character token `<elided>`:
#
#   json_payload.userIamPrincipal        -> "<elided>"   (who asked)
#   json_payload.request.query[...]      -> "<elided>"   (the question)
#   json_payload.response.answer[...]    -> "<elided>"   (the answer)
#
# Setting observabilityConfig.sensitiveLoggingEnabled = true on the engine is
# what makes those fields land in the log as plain text — and therefore in
# gemini_ent_analytics._AllLogs, and therefore in the views built on it.
#
# Views that are EMPTY / DEGENERATE without this flag:
#   - v_user_questions        (question_text + answer_text are the whole point)
#   - v_queries_per_user      (every row collapses onto one `<elided>` user)
#   - v_daily_active_users    (COUNT(DISTINCT user) is always 1)
#   - v_user_activity_detail  (per-user drilldown has a single user)
#   - v_user_agent_trace      (same)
#   - t_content_topics        (sql/02 classifies user_activity question text;
#                              with no text there is nothing to classify)
#
# WHY IT IS OPT-IN (default false)
# --------------------------------
# Turning this on writes end-user prompts and identities in the clear into
# Cloud Logging, and the linked dataset copies them into BigQuery. That is
# real PII leaving the product surface and landing in an analytics store, so
# it must be a deliberate choice, not a default. Before enabling:
#   - restrict IAM on var.analytics_dataset_id and var.dashboard_dataset_id
#     (BigQuery dataset ACLs) to the people allowed to read prompts;
#   - confirm the log bucket's retention (see logging.tf) matches how long
#     you are actually permitted to retain prompt text.
#
# TURNING IT BACK OFF IS MANUAL, BY DESIGN. Setting the flag to false only
# removes this null_resource from state (count -> 0); it does NOT re-PATCH
# the engines, so they keep logging prompt text. That is deliberate: a
# routine `terraform apply` with the default flag must never silently switch
# off logging that someone enabled on purpose (here or in the console). To
# actually revert, PATCH the engine yourself:
#
#   curl -X PATCH -H "Authorization: Bearer $(gcloud auth print-access-token)" \
#     -H "X-Goog-User-Project: PROJECT" \
#     -H "Content-Type: application/json" \
#     -d '{"observabilityConfig":{"sensitiveLoggingEnabled":false}}' \
#     "https://discoveryengine.googleapis.com/v1alpha/projects/PROJECT/locations/global/collections/default_collection/engines/ENGINE?updateMask=observabilityConfig.sensitiveLoggingEnabled"
#
# (Note the leaf-path mask there too — see the updateMask warning below, and
# the X-Goog-User-Project warning for why that header is load-bearing.)
#
# WHAT IT SETS, AND ON WHICH ENGINES
# ----------------------------------
# Two flags matter, and both must be true for v_user_questions to have
# anything in it: observabilityEnabled gates whether the engine logs AT ALL,
# sensitiveLoggingEnabled gates whether those logs keep the text. A fresh
# engine often has no observabilityConfig at all (= not logging).
#
# Which engines get touched depends on var.sensitive_logging_engine_ids:
#
#   empty (default) -> AUTO: flip sensitiveLoggingEnabled only, and only on
#     engines that already have observabilityEnabled=true. Those are the
#     engines already feeding _AllLogs, so this starts no new log stream and
#     adds no bill — it only stops the rows you already collect from arriving
#     as `<elided>`. Engines with observability off are listed and skipped.
#
#   explicit list -> force BOTH flags on for exactly those engines, starting
#     observability (and therefore billable log volume) on an engine that was
#     not logging before.
#
# Auto mode is deliberately NOT "every engine in the project". A Gemini
# Enterprise project routinely holds unrelated search/parser/KB engines — the
# project this was built against has 10 engines of which only 2 feed the
# dashboard. Force-enabling observability across all of them would start
# billable log volume and write those users' prompts in the clear, which is
# not what `-var=enable_sensitive_logging=true` asks for.
#
# *** FORWARD-ONLY — THIS IS THE IMPORTANT PART ***
# -------------------------------------------------
# Exactly like Log Analytics enablement in logging.tf, this is NOT
# retroactive. Logs already written with `<elided>` stay `<elided>` forever;
# no backfill exists. Enabling this a week after deploying means that week of
# questions is permanently unrecoverable. If you want prompt-level analytics
# at all, enable it AT DEPLOY TIME:
#
#   ./deploy.sh <PROJECT_ID> -var="enable_sensitive_logging=true"
#
# ---------------------------------------------------------------------------
# Why null_resource + local-exec (same reasoning as logging.tf)
# ---------------------------------------------------------------------------
# The google provider has no resource for a Discovery Engine engine, let
# alone its observabilityConfig — engines are created by the Gemini
# Enterprise console/product, not by this module, and we only want to flip
# specific fields on a resource we do not own.
#
# *** updateMask MUST name the leaf fields — VERIFIED THE HARD WAY ***
# `?updateMask=observabilityConfig` REPLACES the whole nested message, so a
# body of {"observabilityConfig":{"sensitiveLoggingEnabled":true}} silently
# DROPS observabilityEnabled and the engine stops emitting logs entirely.
# Confirmed against the live API (2026-07-15): a PATCH with that mask turned
# {"observabilityEnabled":true,"sensitiveLoggingEnabled":true} into
# {"sensitiveLoggingEnabled":true} and returned HTTP 200 — a silent outage of
# every dashboard view. Naming both leaf paths explicitly, as below, is what
# keeps the PATCH surgical. Do not "simplify" this mask.
#
# *** X-Goog-User-Project IS NOT OPTIONAL — VERIFIED THE HARD WAY ***
# discoveryengine requires a quota project, and a raw curl carrying only
# `gcloud auth print-access-token` does not send one: gcloud attaches
# x-goog-user-project from core/project itself, but the bare token does not
# carry it. Without the header the API attributes the call to the *gcloud
# CLI's own* client project (32555940559) and rejects it with a 403 whose
# reason is SERVICE_DISABLED — which reads exactly like "the API is off in
# your project" or "you lack discoveryengine.admin", and is neither.
# Confirmed against the live API (2026-07-15): the same GET that a service
# account answers with 200 returns that 403 under a user credential, because
# an SA token carries its own project and a user token does not. Cloud Shell
# runs as a user, which is why this only ever bites there. Sending the header
# needs serviceusage.services.use on var.project_id
# (roles/serviceusage.serviceUsageConsumer; project owners already have it) —
# without it the 403 becomes USER_PROJECT_DENIED naming var.project_id, which
# means the header landed and only IAM is left.
# `gcloud auth application-default set-quota-project` does NOT fix this — ADC
# is not what these calls use. Do not drop the header.
#
# LIMITATIONS (inherited from the local-exec approach):
#   - Not visible in `terraform plan`.
#   - Runs from whatever machine executes `terraform apply`; that principal
#     needs discoveryengine.engines.update (e.g. roles/discoveryengine.admin),
#     serviceusage.services.use (see above), and curl + python3 on PATH.
#   - `triggers` is keyed to the flag + engine list, so it re-runs when you
#     flip the flag or change which engines are targeted — not on every apply.
#   - Engines are assumed to live at locations/global under
#     collections/default_collection, which is where the Gemini Enterprise
#     console creates them.
# ---------------------------------------------------------------------------

resource "null_resource" "enable_sensitive_logging" {
  count = var.enable_sensitive_logging ? 1 : 0

  # count already gates on the flag, so it is never part of the trigger:
  # this resource only exists when enable_sensitive_logging is true.
  triggers = {
    project    = var.project_id
    engine_ids = join(",", var.sensitive_logging_engine_ids)
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      PROJECT="${var.project_id}"
      BASE="https://discoveryengine.googleapis.com/v1alpha/projects/$PROJECT/locations/global/collections/default_collection/engines"

      # Leaf paths only — see the updateMask warning in the header comment.
      MASK="observabilityConfig.observabilityEnabled,observabilityConfig.sensitiveLoggingEnabled"

      TOKEN="$(gcloud auth print-access-token)"

      RESP="$(mktemp)"
      trap 'rm -f "$RESP"' EXIT

      ENGINES="${join(" ", var.sensitive_logging_engine_ids)}"

      if [[ -n "$ENGINES" ]]; then
        # EXPLICIT MODE: the operator named these engines, so force both flags
        # on — including starting observability on an engine that had it off.
        BODY='{"observabilityConfig":{"observabilityEnabled":true,"sensitiveLoggingEnabled":true}}'
        PATCH_MASK="$MASK"
        echo ">>> Explicit engine list — enabling observability + sensitive logging."
      else
        # AUTO MODE (default): only UNMASK engines that are ALREADY logging.
        #
        # Deliberately NOT "every engine in the project". A Gemini Enterprise
        # project routinely holds many engines (search apps, parsers, KBs)
        # that have nothing to do with this dashboard; force-enabling
        # observability on all of them would start billable log volume and
        # start writing their users' prompts in the clear — a blast radius
        # nobody asked for by typing `-var=enable_sensitive_logging=true`.
        # So auto mode only flips sensitiveLoggingEnabled, and only on
        # engines whose observabilityEnabled is already true: those are the
        # engines already feeding _AllLogs, i.e. exactly the ones whose rows
        # show up as `<elided>` in v_user_questions today. No new log source
        # is created; the logs you already pay for stop being masked.
        # Engines that are not logging are listed and skipped — name them in
        # var.sensitive_logging_engine_ids to opt them in explicitly.
        BODY='{"observabilityConfig":{"sensitiveLoggingEnabled":true}}'
        PATCH_MASK="observabilityConfig.sensitiveLoggingEnabled"

        echo ">>> No sensitive_logging_engine_ids set — selecting engines that already have observability on..."

        # Check the HTTP status explicitly: a 403 (missing
        # discoveryengine.engines.list) or 404 also returns a body with no
        # "engines" key, which would otherwise be indistinguishable from a
        # legitimately empty project and get swallowed as a warning.
        HTTP_CODE="$(curl -sS -o "$RESP" -w '%%{http_code}' \
          -H "Authorization: Bearer $TOKEN" \
          -H "X-Goog-User-Project: $PROJECT" "$BASE")"
        if [[ "$HTTP_CODE" != "200" ]]; then
          echo ">>> ERROR: could not list engines in $PROJECT (HTTP $HTTP_CODE)." >&2
          echo ">>> Read the response below before assuming it is IAM. Match the 'reason'" >&2
          echo ">>> and 'consumer' fields against these — they mean different things:" >&2
          echo ">>>   USER_PROJECT_DENIED, consumer $PROJECT" >&2
          echo ">>>     -> the quota project reached the API but this principal may not bill" >&2
          echo ">>>        to it. Grant serviceusage.services.use on $PROJECT:" >&2
          echo ">>>          gcloud projects add-iam-policy-binding $PROJECT \\" >&2
          echo ">>>            --member='user:YOU@example.com' \\" >&2
          echo ">>>            --role='roles/serviceusage.serviceUsageConsumer'" >&2
          echo ">>>   SERVICE_DISABLED, consumer projects/32555940559" >&2
          echo ">>>     -> 32555940559 is the gcloud CLI's own client project, NOT yours." >&2
          echo ">>>        The X-Goog-User-Project header did not reach the API. This is a" >&2
          echo ">>>        bug in this script, not something you can fix with IAM." >&2
          echo ">>>   SERVICE_DISABLED, consumer $PROJECT" >&2
          echo ">>>     -> discoveryengine.googleapis.com really is off. See apis.tf." >&2
          echo ">>>   anything naming discoveryengine.engines.list" >&2
          echo ">>>     -> genuinely missing IAM, e.g. roles/discoveryengine.admin on $PROJECT." >&2
          cat "$RESP" >&2
          exit 1
        fi

        ENGINES="$(python3 -c '
import sys, json
engines = json.load(open(sys.argv[1])).get("engines", [])
on, off = [], []
for e in engines:
    eid = e["name"].rsplit("/", 1)[-1]
    (on if e.get("observabilityConfig", {}).get("observabilityEnabled") else off).append(eid)
for eid in off:
    print("  skipped (observability off): " + eid, file=sys.stderr)
print(" ".join(on))
' "$RESP")"
      fi

      if [[ -z "$ENGINES" ]]; then
        echo ">>> WARNING: no engine in $PROJECT is currently emitting logs, so there is" >&2
        echo ">>> nothing to unmask and the dashboard will stay empty." >&2
        echo ">>> Turn on observability for your Gemini Enterprise app (console:" >&2
        echo ">>> app -> Configurations -> Observability), or name the engines explicitly" >&2
        echo ">>> to have this module enable it for you:" >&2
        echo ">>>   ./deploy.sh $PROJECT -var=\"enable_sensitive_logging=true\" \\" >&2
        echo ">>>     -var='sensitive_logging_engine_ids=[\"ENGINE_ID\"]'" >&2
        exit 0
      fi

      for ENG in $ENGINES; do
        echo ">>> Enabling sensitive logging on engine $ENG"
        HTTP_CODE="$(curl -sS -o "$RESP" -w '%%{http_code}' \
          -X PATCH \
          -H "Authorization: Bearer $TOKEN" \
          -H "X-Goog-User-Project: $PROJECT" \
          -H "Content-Type: application/json" \
          -d "$BODY" \
          "$BASE/$ENG?updateMask=$PATCH_MASK")"

        if [[ "$HTTP_CODE" != "200" ]]; then
          echo ">>> ERROR: PATCH on engine $ENG returned HTTP $HTTP_CODE" >&2
          cat "$RESP" >&2
          exit 1
        fi
      done

      echo ">>> Applied to: $ENGINES"
      echo ">>> REMINDER: forward-only. Logs written before this point stay masked."
    EOT
  }

  depends_on = [google_project_service.apis]
}
