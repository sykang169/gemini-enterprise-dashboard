-- =====================================================================
-- Gemini Enterprise + Model Armor Dashboard -- BigQuery View Definitions
-- =====================================================================
-- Auto-extracted via `bq show --view --format=prettyjson` from the live
-- dataset YOUR_PROJECT_ID:gemini_ent_dashboard on 2026-07-08.
-- This is a multi-statement script: run as-is via `bq query` or a
-- google_bigquery_job Terraform resource. Order matters only in that
-- every v_* view reads gemini_ent_dashboard.v_log_source, which this
-- script defines FIRST -- so order matters now: the archive table and
-- v_log_source must exist before the views that select from them. Among
-- the v_* views themselves nothing depends on anything else, so
-- CREATE OR REPLACE stays re-runnable.
--
-- Content-classification views (v_topic_distribution, v_intent_distribution,
-- v_sentiment_daily) live separately in sql/02_content_classification.sql
-- because they depend on the Gemini remote model and incur per-row cost.
-- =====================================================================

-- =====================================================================
-- STEP 0 -- the log source every view reads
-- =====================================================================
-- WHY THIS EXISTS: gemini_ent_analytics._AllLogs is a LINKED dataset -- a
-- VIEW over the _Default log bucket that stores 0 bytes of its own (verified:
-- type=VIEW, numBytes=0). The bucket's retention is therefore a hard floor on
-- how far back ANY view can see: at the default 30 days the whole dashboard
-- silently becomes a 30-day rolling window, and expired logs are gone for
-- good (Log Analytics has no backfill).
--
-- v_log_source stitches the two halves together:
--   t_logs_archive  -- durable copy (sql/03_archive_logs.sql), outlives
--                      retention expiry
--   _AllLogs        -- everything newer than the archive's watermark, so the
--                      dashboard stays live between archive runs
-- Views read this instead of _AllLogs and get permanent history plus fresh
-- rows without a single per-view change.

-- The archive table is created HERE, not in sql/03, even though sql/03 is
-- what fills it. Reason: sql/03 is opt-in (var.enable_log_archive) but
-- v_log_source references the table unconditionally -- if the table only
-- existed when archiving was on, every default deploy would die on "table not
-- found". Created empty, it lets v_log_source degrade cleanly to "just
-- _AllLogs": exactly the pre-archive behaviour.
CREATE TABLE IF NOT EXISTS `YOUR_PROJECT_ID.gemini_ent_dashboard.t_logs_archive`
PARTITION BY DATE(timestamp)
CLUSTER BY log_name
OPTIONS (
  description = "Durable copy of the dashboard's source logs, surviving _Default bucket retention. Created empty by sql/01; filled incrementally by sql/03_archive_logs.sql when var.enable_log_archive is on. Deduped on (log_name, timestamp, insert_id)."
)
AS SELECT * FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs` WHERE FALSE
;

CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source` AS
-- ARCHIVE-ONLY, AND THAT IS THE WHOLE POINT.
-- This used to UNION the archive with _AllLogs so charts were real-time. That
-- cost far more than it looked. _AllLogs is partitioned by day only -- there is
-- no way to prune it by log_name -- so ANY read of it drags in every unrelated
-- log in the window (Cloud Run, agents, GCE...), which is 73% of the bucket,
-- and reads their json_payload column in full. Measured on the live dataset:
--
--   SELECT * FROM t_logs_archive .......... 2.32 MB
--   SELECT * FROM v_log_source (w/ UNION) . 5,930 MB      <- 2,556x more
--
-- A 20-chart Looker dashboard re-queries every view on load, so that union was
-- ~118 GB (~$0.59) PER PAGE LOAD, and it scaled with total log volume rather
-- than with the dashboard's own data. Reading only the archive -- pre-filtered
-- to the logs the views need, partitioned by day, clustered by log_name --
-- made the same page load ~46 MB.
--
-- FRESHNESS: the dashboard is as fresh as the last archive run (hourly, see
-- var.archive_schedule), not real-time. Every metric here is a daily
-- aggregate, so an hour of lag does not change what anyone reads off a chart.
-- If the archive stops, the dashboard goes stale rather than wrong, and the
-- next successful run backfills the gap (watermark logic in sql/03).
--
-- ---------------------------------------------------------------------
-- THE WINDOW: why charts are capped at DASHBOARD_WINDOW_DAYS days
-- ---------------------------------------------------------------------
-- Archive-only fixed the constant factor, not the growth. The archive is
-- append-only forever, so without a bound every chart's scan grows for the
-- life of the deployment -- a 3-year-old install would scan 3 years of logs to
-- draw "queries per day", every refresh, forever.
--
-- A date filter DOES prune through these views -- verified on the live
-- dataset, filtering the aggregate views' `day` column (a TIMESTAMP_TRUNC of
-- the partition column) still prunes partitions:
--   v_daily_queries  no filter 1,345,193 B -> WHERE day >= ... 935,881 B
--   v_user_questions no filter 1,448,621 B -> WHERE day >= ... 1,032,339 B
-- So a Looker report WITH a date-range control already prunes. The bound below
-- exists for the report WITHOUT one: a chart dropped on a page with no date
-- control sends no filter and would scan the entire archive. The default is
-- the safety net, not a replacement for date controls.
--
-- This does NOT shrink the archive or lose history. t_logs_archive still holds
-- everything, and v_log_source_all (below) reads it unbounded for ad-hoc and
-- compliance queries. This only bounds what the CHARTS reach for by default.
--
-- Sized against retention, not taste: the log bucket keeps 30 days, so a
-- 90-day default still shows 3x what the logs alone could. Raise it with
-- var.dashboard_window_days (0 = unbounded) if you need longer trends on the
-- dashboard itself, and accept the scan.
SELECT * FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.t_logs_archive`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL DASHBOARD_WINDOW_DAYS DAY)
;

-- Unbounded view over the full archive, for ad-hoc SQL and compliance/export
-- questions ("what did anyone ask in March?") that legitimately need history
-- older than the dashboard window. Deliberately NOT what the v_* views read:
-- point a Looker chart at this and you are back to scanning the whole archive
-- on every refresh. Always filter it by timestamp.
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source_all` AS
SELECT * FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.t_logs_archive`
;

-- ---------------------------------------------------------------------
-- v_daily_queries
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_daily_queries` AS
-- engine_id = which Gemini Enterprise app served the query, so a shared
-- project can slice per app. It is a COALESCE because the field moves: for
-- Search/StreamAssist the engine is a segment of logMetadata.name, but for
-- WriteUserEvent that name is only "projects/<n>/locations/global" and the
-- engine lives in request.userEvent.engine instead. resource.labels does NOT
-- carry it on user_activity rows (it is `consumed_api` there) -- only gen_ai
-- rows get a structured resource.labels.engine_id. Verified: the COALESCE
-- resolves an engine for 100% of user_activity rows across all methods.
SELECT TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  COALESCE(
    REGEXP_EXTRACT(JSON_VALUE(json_payload.logMetadata.name), r"/engines/([^/]+)"),
    REGEXP_EXTRACT(JSON_VALUE(json_payload.request.userEvent.engine), r"/engines/([^/]+)")
  ) AS engine_id,
  COUNT(*) AS queries
FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source` WHERE log_name LIKE '%gemini_enterprise_user_activity' AND JSON_VALUE(json_payload,'$.logMetadata.methodName') IN ('Search','StreamAssist') GROUP BY day, engine_id
;

-- ---------------------------------------------------------------------
-- v_daily_queries_by_method
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_daily_queries_by_method` AS
SELECT TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  JSON_VALUE(json_payload,'$.logMetadata.methodName') AS method, COUNT(*) AS calls
FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source` WHERE log_name LIKE '%gemini_enterprise_user_activity' AND JSON_VALUE(json_payload,'$.logMetadata.methodName') IN ('Search','StreamAssist') GROUP BY day, method
;

-- ---------------------------------------------------------------------
-- v_daily_agent_calls
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_daily_agent_calls` AS
SELECT TIMESTAMP_TRUNC(timestamp, DAY) AS day, COUNT(*) AS agent_calls
FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source` WHERE log_name LIKE '%gemini_enterprise_user_activity' AND JSON_VALUE(json_payload,'$.logMetadata.methodName')='StreamAssist' GROUP BY day
;

-- ---------------------------------------------------------------------
-- v_queries_per_user
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_queries_per_user` AS
SELECT JSON_VALUE(json_payload,'$.userIamPrincipal') AS user_id,
  COUNTIF(JSON_VALUE(json_payload,'$.logMetadata.methodName')='StreamAssist') AS agent_calls,
  COUNTIF(JSON_VALUE(json_payload,'$.logMetadata.methodName')='Search') AS searches,
  COUNT(*) AS total_queries
FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source` WHERE log_name LIKE '%gemini_enterprise_user_activity' AND JSON_VALUE(json_payload,'$.logMetadata.methodName') IN ('Search','StreamAssist') GROUP BY user_id
;

-- ---------------------------------------------------------------------
-- v_daily_active_users
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_daily_active_users` AS
SELECT TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  COUNT(DISTINCT JSON_VALUE(json_payload,'$.userIamPrincipal')) AS active_users,
  COUNT(*) AS queries,
  ROUND(SAFE_DIVIDE(COUNT(*),COUNT(DISTINCT JSON_VALUE(json_payload,'$.userIamPrincipal'))),2) AS queries_per_user
FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source` WHERE log_name LIKE '%gemini_enterprise_user_activity' AND JSON_VALUE(json_payload,'$.logMetadata.methodName') IN ('Search','StreamAssist') GROUP BY day
;

-- ---------------------------------------------------------------------
-- v_daily_failure_rate
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_daily_failure_rate` AS
SELECT TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  COUNTIF(severity IN ('ERROR','CRITICAL','ALERT','EMERGENCY')) AS failures,
  COUNT(*) AS total,
  ROUND(SAFE_DIVIDE(COUNTIF(severity IN ('ERROR','CRITICAL','ALERT','EMERGENCY')),COUNT(*))*100,2) AS failure_pct
FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source` WHERE log_name LIKE '%gemini_enterprise_user_activity' GROUP BY day
;

-- ---------------------------------------------------------------------
-- v_streamassist_state
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_streamassist_state` AS
SELECT TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  COALESCE(JSON_VALUE(json_payload,'$.response.answer.state'),'UNKNOWN') AS state, COUNT(*) AS n
FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source` WHERE log_name LIKE '%gemini_enterprise_user_activity' AND JSON_VALUE(json_payload,'$.logMetadata.methodName')='StreamAssist' GROUP BY day, state
;

-- ---------------------------------------------------------------------
-- v_model_armor_block
-- ---------------------------------------------------------------------
-- ---------------------------------------------------------------------
-- Model Armor views: why every one of them filters on client_name
-- ---------------------------------------------------------------------
-- A project-wide Model Armor floor setting inspects EVERY Vertex AI call in
-- the project -- including this dashboard's own ML.GENERATE_TEXT content
-- classification (sql/02). Those self-inflicted checks are logged as
-- sanitize_operations rows with client_name=VERTEX_AI and are
-- indistinguishable from user traffic by log_name alone.
--
-- Measured on the source project (38 days, before the junk was purged):
--   client_name=VERTEX_AI              765,875 rows  (99.93%)  <- this dashboard
--   client_name=GEMINI_ENTERPRISE_*        527 rows  ( 0.07%)  <- real users
-- Unfiltered, these views reported the dashboard classifying its own prompts
-- as if it were end-user activity: 2026-07-13 showed 420,692 "inspected"
-- prompts on a day with ZERO real user prompts.
--
-- client_name lives in `labels`, NOT in resource.labels, and the key contains
-- dots and a slash -- hence the quoted JSON path below. Real Gemini Enterprise
-- traffic is GEMINI_ENTERPRISE_BUSINESS / GEMINI_ENTERPRISE_NON_BUSINESS, so
-- the LIKE prefix catches both. Do not drop this filter to "simplify" the
-- views: it is what separates user behaviour from the dashboard's own exhaust.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_model_armor_block` AS
SELECT TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  JSON_VALUE(json_payload,'$.operationType') AS operation,
  COUNTIF(JSON_VALUE(json_payload,'$.sanitizationResult.filterMatchState')='MATCH_FOUND') AS blocked,
  COUNT(*) AS inspected,
  ROUND(SAFE_DIVIDE(COUNTIF(JSON_VALUE(json_payload,'$.sanitizationResult.filterMatchState')='MATCH_FOUND'),COUNT(*))*100,2) AS block_pct
FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source` WHERE log_name LIKE '%sanitize_operations'
  AND JSON_VALUE(labels,'$."modelarmor.googleapis.com/client_name"') LIKE 'GEMINI_ENTERPRISE%' GROUP BY day, operation
;

-- ---------------------------------------------------------------------
-- v_model_armor_threats
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_model_armor_threats` AS
SELECT TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  COUNTIF(JSON_VALUE(json_payload,'$.sanitizationResult.filterResults.rai.raiFilterResult.raiFilterTypeResults.dangerous.matchState')='MATCH_FOUND') AS dangerous,
  COUNTIF(JSON_VALUE(json_payload,'$.sanitizationResult.filterResults.rai.raiFilterResult.raiFilterTypeResults.harassment.matchState')='MATCH_FOUND') AS harassment,
  COUNTIF(JSON_VALUE(json_payload,'$.sanitizationResult.filterResults.rai.raiFilterResult.raiFilterTypeResults.hate_speech.matchState')='MATCH_FOUND') AS hate_speech,
  COUNTIF(JSON_VALUE(json_payload,'$.sanitizationResult.filterResults.rai.raiFilterResult.raiFilterTypeResults.sexually_explicit.matchState')='MATCH_FOUND') AS sexually_explicit,
  COUNTIF(JSON_VALUE(json_payload,'$.sanitizationResult.filterResults.csam.csamFilterFilterResult.matchState')='MATCH_FOUND') AS csam
FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source` WHERE log_name LIKE '%sanitize_operations'
  AND JSON_VALUE(labels,'$."modelarmor.googleapis.com/client_name"') LIKE 'GEMINI_ENTERPRISE%' GROUP BY day
;

-- ---------------------------------------------------------------------
-- v_model_armor_threats_long
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_model_armor_threats_long` AS
WITH base AS (
 SELECT day,
  SUM(dangerous) dangerous, SUM(harassment) harassment, SUM(hate_speech) hate_speech,
  SUM(sexually_explicit) sexually_explicit, SUM(csam) csam, SUM(prompt_injection) prompt_injection
 FROM (
  SELECT TIMESTAMP_TRUNC(timestamp,DAY) day,
   COUNTIF(JSON_VALUE(json_payload,'$.sanitizationResult.filterResults.rai.raiFilterResult.raiFilterTypeResults.dangerous.matchState')='MATCH_FOUND') dangerous,
   COUNTIF(JSON_VALUE(json_payload,'$.sanitizationResult.filterResults.rai.raiFilterResult.raiFilterTypeResults.harassment.matchState')='MATCH_FOUND') harassment,
   COUNTIF(JSON_VALUE(json_payload,'$.sanitizationResult.filterResults.rai.raiFilterResult.raiFilterTypeResults.hate_speech.matchState')='MATCH_FOUND') hate_speech,
   COUNTIF(JSON_VALUE(json_payload,'$.sanitizationResult.filterResults.rai.raiFilterResult.raiFilterTypeResults.sexually_explicit.matchState')='MATCH_FOUND') sexually_explicit,
   COUNTIF(JSON_VALUE(json_payload,'$.sanitizationResult.filterResults.csam.csamFilterFilterResult.matchState')='MATCH_FOUND') csam,
   COUNTIF(JSON_VALUE(json_payload,'$.sanitizationResult.filterResults.pi_and_jailbreak.piAndJailbreakFilterResult.matchState')='MATCH_FOUND') prompt_injection
  FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source` WHERE log_name LIKE '%sanitize_operations'
  AND JSON_VALUE(labels,'$."modelarmor.googleapis.com/client_name"') LIKE 'GEMINI_ENTERPRISE%' GROUP BY day )
 GROUP BY day )
SELECT day, threat_type, threat_count FROM base
UNPIVOT(threat_count FOR threat_type IN (dangerous,harassment,hate_speech,sexually_explicit,csam,prompt_injection))
;

-- ---------------------------------------------------------------------
-- v_hourly_heatmap
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_hourly_heatmap` AS
SELECT FORMAT_TIMESTAMP('%A', timestamp) AS weekday, EXTRACT(HOUR FROM timestamp) AS hour_of_day, COUNT(*) AS queries
FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source` WHERE log_name LIKE '%gemini_enterprise_user_activity' AND JSON_VALUE(json_payload,'$.logMetadata.methodName') IN ('Search','StreamAssist') GROUP BY weekday, hour_of_day
;

-- ---------------------------------------------------------------------
-- v_agent_usage_daily
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_agent_usage_daily` AS
-- Per-agent invocations. Source is user_activity's request.agentsSpec, NOT
-- gen_ai's resource.labels.agent_id.
--
-- *** WHY NOT gen_ai.resource.labels.agent_id ***
-- That label looks like exactly the right field and is what this view used to
-- read. It is useless for this question: it identifies the ASSISTANT that
-- served the turn, not the agent the user picked. Verified on the live
-- dataset -- across all 2,927 gen_ai rows it has exactly ONE distinct value:
--   {"agent_id":"core_assistant","assistant_id":"default_assistant",
--    "engine_id":"gemini-enterprise-17821883_...", ...}
-- So the old view reported "one agent, all traffic" no matter how many custom
-- agents existed (19 in the source project) or which ones ran. It was not
-- empty, which is worse -- it was confidently wrong.
--
-- The agent the caller actually invoked is in the StreamAssist REQUEST:
--   request.agentsSpec.agentSpecs[].agentId
-- It is an array because a turn can address more than one agent, hence the
-- UNNEST. Values are either a numeric custom-agent id (e.g. 2449938318073800485)
-- or a built-in slug (deep_research, default_idea_generation).
--
-- COVERAGE, HONESTLY: only turns that target an agent carry agentsSpec.
-- Ordinary assistant chat has no agentsSpec and is absent here by design --
-- this view answers "which agents get used", not "how much traffic exists".
-- Agent *page views* (someone browsing the gallery) are a different signal and
-- live in v_agent_page_views below.
--
-- Display names are NOT in the logs (the API has them; the logs carry ids
-- only, and pre-sensitive-logging rows elide even those). Join to your own
-- agent inventory if you need names.
SELECT
  TIMESTAMP_TRUNC(t.timestamp, DAY) AS day,
  COALESCE(
    REGEXP_EXTRACT(JSON_VALUE(t.json_payload.logMetadata.name), r"/engines/([^/]+)"),
    REGEXP_EXTRACT(JSON_VALUE(t.json_payload.request.userEvent.engine), r"/engines/([^/]+)")
  ) AS engine_id,
  JSON_VALUE(a, '$.agentId') AS agent_id,
  COUNT(*) AS calls,
  COUNT(DISTINCT JSON_VALUE(t.json_payload.userIamPrincipal)) AS users
FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source` AS t,
  UNNEST(JSON_QUERY_ARRAY(t.json_payload.request.agentsSpec.agentSpecs)) AS a
WHERE t.log_name LIKE '%gemini_enterprise_user_activity'
GROUP BY day, engine_id, agent_id
;

-- ---------------------------------------------------------------------
-- v_agent_page_views
-- ---------------------------------------------------------------------
-- Which agents users BROWSE, from WriteUserEvent UI telemetry
-- (request.userEvent.agentspaceInfo). This is discovery/interest, not usage:
-- eventType=view-category-page with agentspacePageType=agent means someone
-- opened an agent's page. Read together with v_agent_usage_daily it shows the
-- gap between agents people look at and agents people actually run.
--
-- Note the engine here comes from request.userEvent.engine, NOT
-- logMetadata.name -- for WriteUserEvent the latter is just
-- "projects/<n>/locations/global" with no engine segment. That asymmetry is
-- why every engine_id expression in this file is a COALESCE of the two.
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_agent_page_views` AS
SELECT
  TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  REGEXP_EXTRACT(JSON_VALUE(json_payload.request.userEvent.engine), r"/engines/([^/]+)") AS engine_id,
  JSON_VALUE(json_payload.request.userEvent.agentspaceInfo.agentInfo.agentId) AS agent_id,
  JSON_VALUE(json_payload.request.userEvent.agentspaceInfo.agentspacePageType) AS page_type,
  COUNT(*) AS views,
  COUNT(DISTINCT JSON_VALUE(json_payload.userIamPrincipal)) AS users
FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source`
WHERE log_name LIKE '%gemini_enterprise_user_activity'
  AND JSON_VALUE(json_payload.logMetadata.methodName) = 'WriteUserEvent'
  AND JSON_VALUE(json_payload.request.userEvent.agentspaceInfo.agentInfo.agentId) IS NOT NULL
GROUP BY day, engine_id, agent_id, page_type
;

-- ---------------------------------------------------------------------
-- v_response_latency_daily
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_response_latency_daily` AS
WITH g AS (
  SELECT trace, JSON_VALUE(resource.labels,'$.agent_id') AS agent_id,
    JSON_VALUE(labels,'$."event.name"') AS ev, timestamp
  FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source`
  WHERE (log_name LIKE '%gen_ai.user.message' OR log_name LIKE '%gen_ai.choice') AND trace IS NOT NULL ),
per_trace AS (
  SELECT trace, ANY_VALUE(agent_id) agent_id,
    MAX(IF(ev='gen_ai.user.message',timestamp,NULL)) req_ts,
    MAX(IF(ev='gen_ai.choice',timestamp,NULL)) resp_ts
  FROM g GROUP BY trace )
SELECT TIMESTAMP_TRUNC(resp_ts,DAY) AS day, agent_id, COUNT(*) AS responses,
  ROUND(APPROX_QUANTILES(TIMESTAMP_DIFF(resp_ts,req_ts,MILLISECOND),100)[OFFSET(50)]/1000,2) AS p50_sec,
  ROUND(APPROX_QUANTILES(TIMESTAMP_DIFF(resp_ts,req_ts,MILLISECOND),100)[OFFSET(95)]/1000,2) AS p95_sec
FROM per_trace
WHERE req_ts IS NOT NULL AND resp_ts IS NOT NULL AND resp_ts>=req_ts
GROUP BY day, agent_id
;

-- ---------------------------------------------------------------------
-- v_grounding_top_sources
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_grounding_top_sources` AS
SELECT COALESCE(NULLIF(JSON_VALUE(ref,'$.documentMetadata.domain'),''),
                NET.HOST(JSON_VALUE(ref,'$.documentMetadata.uri')),'(unknown)') AS source,
  COUNT(*) AS citations
FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source`,
  UNNEST(JSON_QUERY_ARRAY(json_payload,'$.response.answer.replies')) rep,
  UNNEST(JSON_QUERY_ARRAY(rep,'$.groundedContent.textGroundingMetadata.references')) ref
WHERE log_name LIKE '%gemini_enterprise_user_activity'
GROUP BY source
;

-- ---------------------------------------------------------------------
-- v_grounding_coverage_daily
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_grounding_coverage_daily` AS
SELECT TIMESTAMP_TRUNC(timestamp,DAY) AS day,
  COUNT(*) AS answers,
  COUNTIF(ref_count>0) AS grounded_answers,
  ROUND(SAFE_DIVIDE(COUNTIF(ref_count>0),COUNT(*))*100,2) AS grounded_pct,
  ROUND(AVG(ref_count),2) AS avg_sources_per_answer
FROM (
  SELECT timestamp,
    (SELECT COUNT(*) FROM UNNEST(JSON_QUERY_ARRAY(json_payload,'$.response.answer.replies')) rep,
       UNNEST(JSON_QUERY_ARRAY(rep,'$.groundedContent.textGroundingMetadata.references')) ref) AS ref_count
  FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source`
  WHERE log_name LIKE '%gemini_enterprise_user_activity'
    AND JSON_VALUE(json_payload,'$.logMetadata.methodName')='StreamAssist' )
GROUP BY day
;

-- ---------------------------------------------------------------------
-- v_user_activity_detail
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_user_activity_detail` AS
SELECT timestamp, TIMESTAMP_TRUNC(timestamp,DAY) AS day,
  JSON_VALUE(json_payload,'$.userIamPrincipal') AS user_id,
  JSON_VALUE(json_payload,'$.logMetadata.methodName') AS method,
  COALESCE(JSON_VALUE(json_payload,'$.response.answer.state'),'') AS state,
  (SELECT COUNT(*) FROM UNNEST(JSON_QUERY_ARRAY(json_payload,'$.response.answer.replies')) rep,
     UNNEST(JSON_QUERY_ARRAY(rep,'$.groundedContent.textGroundingMetadata.references')) ref) AS source_count,
  severity
FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source`
WHERE log_name LIKE '%gemini_enterprise_user_activity'
  AND JSON_VALUE(json_payload,'$.logMetadata.methodName') IN ('Search','StreamAssist')
;

-- ---------------------------------------------------------------------
-- v_model_armor_by_client
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_model_armor_by_client` AS
SELECT TIMESTAMP_TRUNC(timestamp,DAY) AS day,
  JSON_VALUE(labels,'$."modelarmor.googleapis.com/client_name"') AS client_name,
  JSON_VALUE(json_payload,'$.operationType') AS operation,
  JSON_VALUE(resource.labels,'$.template_id') AS template_id,
  COUNTIF(JSON_VALUE(json_payload,'$.sanitizationResult.filterMatchState')='MATCH_FOUND') AS blocked,
  COUNT(*) AS inspected,
  ROUND(SAFE_DIVIDE(COUNTIF(JSON_VALUE(json_payload,'$.sanitizationResult.filterMatchState')='MATCH_FOUND'),COUNT(*))*100,2) AS block_pct
FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source` WHERE log_name LIKE '%sanitize_operations'
  AND JSON_VALUE(labels,'$."modelarmor.googleapis.com/client_name"') LIKE 'GEMINI_ENTERPRISE%'
GROUP BY day, client_name, operation, template_id
;

-- ---------------------------------------------------------------------
-- v_user_agent_trace
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_user_agent_trace` AS
WITH ua AS (
  SELECT trace, MAX(JSON_VALUE(json_payload,'$.userIamPrincipal')) user_id
  FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source` WHERE log_name LIKE '%gemini_enterprise_user_activity' AND trace IS NOT NULL GROUP BY trace ),
ga AS (
  SELECT trace,
    MAX(JSON_VALUE(resource.labels,'$.agent_id')) agent_id,
    MAX(IF(JSON_VALUE(labels,'$."event.name"')='gen_ai.user.message',timestamp,NULL)) req_ts,
    MAX(IF(JSON_VALUE(labels,'$."event.name"')='gen_ai.choice',timestamp,NULL)) resp_ts
  FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source` WHERE log_name LIKE '%2Fgen_ai%' AND trace IS NOT NULL GROUP BY trace )
SELECT TIMESTAMP_TRUNC(COALESCE(ga.req_ts,ga.resp_ts),DAY) AS day,
  ua.user_id, ga.agent_id,
  COUNT(*) AS turns,
  ROUND(AVG(TIMESTAMP_DIFF(ga.resp_ts,ga.req_ts,MILLISECOND))/1000,2) AS avg_latency_sec
FROM ga JOIN ua USING(trace)
GROUP BY day, user_id, agent_id
;

-- ---------------------------------------------------------------------
-- v_model_armor_verdict_daily
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_model_armor_verdict_daily` AS
SELECT TIMESTAMP_TRUNC(timestamp,DAY) AS day,
  JSON_VALUE(json_payload,'$.operationType') AS operation,
  COUNT(*) AS checks,
  COUNTIF(JSON_VALUE(json_payload,'$.sanitizationResult.sanitizationVerdict')='MODEL_ARMOR_SANITIZATION_VERDICT_BLOCK') AS blocked,
  COUNTIF(JSON_VALUE(json_payload,'$.sanitizationResult.filterResults.pi_and_jailbreak.piAndJailbreakFilterResult.matchState')='MATCH_FOUND') AS injection_attempts
FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source` WHERE log_name LIKE '%sanitize_operations'
  AND JSON_VALUE(labels,'$."modelarmor.googleapis.com/client_name"') LIKE 'GEMINI_ENTERPRISE%'
GROUP BY day, operation
;

-- ---------------------------------------------------------------------
-- v_user_questions
--   Row-level Q&A view: the question each user asked AND the assistant's
--   answer, one row per query (no conversation-history duplication).
--   Source: gemini_enterprise_user_activity log -- both question and
--   answer live in the SAME row, so no join is needed. user_id comes
--   straight from userIamPrincipal.
--
--   STREAMASSIST ONLY, DELIBERATELY. This view used to also carry the
--   Search rows and expose a `method` column to tell them apart. The two
--   are different events, not two flavours of one: StreamAssist is an
--   assistant turn (question + generated answer), Search is a keyword
--   lookup that returns hits and NEVER produces an answer. Mixing them
--   meant answer_text was structurally null on ~45% of rows (measured on
--   the live dataset: 93 of 207) -- not missing data, just a column that
--   could not apply -- and every reader had to know to filter on `method`
--   first. Search rows now live in v_search_queries, which has no answer
--   column at all. The `method` column is gone with them: it is constant
--   here, so it only ever said "StreamAssist" 114 times.
--   Do not "restore" it by widening the filter.
--
--     question_text: $.request.query.parts[].text.
--     answer_text: grounded answers -> the answer is split across
--       $...replies[].groundedContent.textGroundingMetadata.segments[].text,
--       reassembled in startIndex order; ungrounded answers (state
--       SKIPPED) -> $...replies[].groundedContent.content.text. COALESCE
--       picks whichever shape the row uses.
--
--   answer_text IS STILL NULL SOMETIMES, for reasons no view can fix
--   (counts below measured on the live dataset 2026-07-15, 114 rows):
--     - turns logged before sensitiveLoggingEnabled took effect: request
--       .query is `{}` and serviceTextReply is the literal "<elided>".
--       Masked at the source, forward-only, unrecoverable. 93 of 114 rows
--       -- the flag was flipped partway through 2026-07-14, so that day
--       has masked and unmasked turns in it.
--     - a few SUCCEEDED turns log `groundedContent: {}` -- an empty reply
--       with no text anywhere in it (7 rows). Nothing to extract.
--   So a null answer_text next to a real question_text means "the log has
--   no answer", not "the extraction missed it".
--   REQUIRES sensitive logging: the engine's
--   observabilityConfig.sensitiveLoggingEnabled must be true, otherwise
--   userIamPrincipal / question / answer are masked to the literal
--   "<elided>" (8 chars) at the source. Not retroactive -- only logs
--   written after enabling are un-masked.
--   Use in Looker Studio as a Table chart with the built-in search box,
--   or an Advanced Filter (contains) on question_text / answer_text,
--   combined with user_id / day controls to drill down.
--   PRIVACY: this exposes raw prompt AND answer text + user identity --
--   restrict report sharing and dataset IAM.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_user_questions` AS
SELECT
  timestamp,
  TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  COALESCE(
    REGEXP_EXTRACT(JSON_VALUE(json_payload.logMetadata.name), r"/engines/([^/]+)"),
    REGEXP_EXTRACT(JSON_VALUE(json_payload.request.userEvent.engine), r"/engines/([^/]+)")
  ) AS engine_id,
  JSON_VALUE(json_payload,'$.userIamPrincipal') AS user_id,
  -- Scalar $.request.query was the Search shape; StreamAssist always uses
  -- the parts[] object, so no COALESCE is needed here any more.
  (SELECT STRING_AGG(JSON_VALUE(p,'$.text'), '\n')
     FROM UNNEST(JSON_QUERY_ARRAY(json_payload,'$.request.query.parts')) p
     WHERE JSON_VALUE(p,'$.text') IS NOT NULL) AS question_text,
  COALESCE(
    (SELECT STRING_AGG(JSON_VALUE(seg,'$.text'), '' ORDER BY SAFE_CAST(JSON_VALUE(seg,'$.startIndex') AS INT64))
       FROM UNNEST(JSON_QUERY_ARRAY(json_payload,'$.response.answer.replies')) r,
            UNNEST(JSON_QUERY_ARRAY(r,'$.groundedContent.textGroundingMetadata.segments')) seg),
    (SELECT MAX(JSON_VALUE(r,'$.groundedContent.content.text'))
       FROM UNNEST(JSON_QUERY_ARRAY(json_payload,'$.response.answer.replies')) r)
  ) AS answer_text,
  trace
FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source`
WHERE log_name LIKE '%gemini_enterprise_user_activity'
  AND JSON_VALUE(json_payload,'$.logMetadata.methodName') = 'StreamAssist'
;

-- ---------------------------------------------------------------------
-- v_search_queries
--   The Search half of gemini_enterprise_user_activity: keyword lookups
--   against an engine's data stores. Split out of v_user_questions (see
--   that view's comment) because a Search event has no assistant answer
--   to show -- it returns hits, not generated text. Giving it its own
--   view means it has no answer column to leave empty, and the Q&A view
--   has no rows that can never be answered.
--
--   query_text reads $.request.query as a SCALAR STRING here. That is the
--   Search shape; StreamAssist nests the same field as an object under
--   $.request.query.parts[]. Same JSON path, different type, which is why
--   one COALESCE used to cover both and read as if the shapes were
--   interchangeable. They are not.
--
--   No answer_text, and no `method` column: every row here is a Search.
--   PRIVACY: exposes raw query text + user identity, same as
--   v_user_questions -- restrict report sharing and dataset IAM.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_search_queries` AS
SELECT
  timestamp,
  TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  COALESCE(
    REGEXP_EXTRACT(JSON_VALUE(json_payload.logMetadata.name), r"/engines/([^/]+)"),
    REGEXP_EXTRACT(JSON_VALUE(json_payload.request.userEvent.engine), r"/engines/([^/]+)")
  ) AS engine_id,
  JSON_VALUE(json_payload,'$.userIamPrincipal') AS user_id,
  JSON_VALUE(json_payload,'$.request.query') AS query_text,
  trace
FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.v_log_source`
WHERE log_name LIKE '%gemini_enterprise_user_activity'
  AND JSON_VALUE(json_payload,'$.logMetadata.methodName') = 'Search'
;
