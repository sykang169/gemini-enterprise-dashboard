-- =====================================================================
-- Gemini Enterprise + Model Armor Dashboard -- BigQuery View Definitions
-- =====================================================================
-- Auto-extracted via `bq show --view --format=prettyjson` from the live
-- dataset YOUR_PROJECT_ID:gemini_ent_dashboard on 2026-07-08.
-- This is a multi-statement script: run as-is via `bq query` or a
-- google_bigquery_job Terraform resource. Order matters only in that
-- none of these views currently depend on one another (all read from
-- gemini_ent_analytics._AllLogs directly), so CREATE OR REPLACE is safe
-- to run in any order / re-run idempotently.
--
-- Content-classification views (v_topic_distribution, v_intent_distribution,
-- v_sentiment_daily) live separately in sql/02_content_classification.sql
-- because they depend on the Gemini remote model and incur per-row cost.
-- =====================================================================

-- ---------------------------------------------------------------------
-- v_daily_queries
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_daily_queries` AS
SELECT TIMESTAMP_TRUNC(timestamp, DAY) AS day, COUNT(*) AS queries
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs` WHERE log_name LIKE '%gemini_enterprise_user_activity' AND JSON_VALUE(json_payload,'$.logMetadata.methodName') IN ('Search','StreamAssist') GROUP BY day
;

-- ---------------------------------------------------------------------
-- v_daily_queries_by_method
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_daily_queries_by_method` AS
SELECT TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  JSON_VALUE(json_payload,'$.logMetadata.methodName') AS method, COUNT(*) AS calls
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs` WHERE log_name LIKE '%gemini_enterprise_user_activity' AND JSON_VALUE(json_payload,'$.logMetadata.methodName') IN ('Search','StreamAssist') GROUP BY day, method
;

-- ---------------------------------------------------------------------
-- v_daily_agent_calls
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_daily_agent_calls` AS
SELECT TIMESTAMP_TRUNC(timestamp, DAY) AS day, COUNT(*) AS agent_calls
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs` WHERE log_name LIKE '%gemini_enterprise_user_activity' AND JSON_VALUE(json_payload,'$.logMetadata.methodName')='StreamAssist' GROUP BY day
;

-- ---------------------------------------------------------------------
-- v_queries_per_user
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_queries_per_user` AS
SELECT JSON_VALUE(json_payload,'$.userIamPrincipal') AS user_id,
  COUNTIF(JSON_VALUE(json_payload,'$.logMetadata.methodName')='StreamAssist') AS agent_calls,
  COUNTIF(JSON_VALUE(json_payload,'$.logMetadata.methodName')='Search') AS searches,
  COUNT(*) AS total_queries
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs` WHERE log_name LIKE '%gemini_enterprise_user_activity' AND JSON_VALUE(json_payload,'$.logMetadata.methodName') IN ('Search','StreamAssist') GROUP BY user_id
;

-- ---------------------------------------------------------------------
-- v_daily_active_users
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_daily_active_users` AS
SELECT TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  COUNT(DISTINCT JSON_VALUE(json_payload,'$.userIamPrincipal')) AS active_users,
  COUNT(*) AS queries,
  ROUND(SAFE_DIVIDE(COUNT(*),COUNT(DISTINCT JSON_VALUE(json_payload,'$.userIamPrincipal'))),2) AS queries_per_user
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs` WHERE log_name LIKE '%gemini_enterprise_user_activity' AND JSON_VALUE(json_payload,'$.logMetadata.methodName') IN ('Search','StreamAssist') GROUP BY day
;

-- ---------------------------------------------------------------------
-- v_daily_failure_rate
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_daily_failure_rate` AS
SELECT TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  COUNTIF(severity IN ('ERROR','CRITICAL','ALERT','EMERGENCY')) AS failures,
  COUNT(*) AS total,
  ROUND(SAFE_DIVIDE(COUNTIF(severity IN ('ERROR','CRITICAL','ALERT','EMERGENCY')),COUNT(*))*100,2) AS failure_pct
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs` WHERE log_name LIKE '%gemini_enterprise_user_activity' GROUP BY day
;

-- ---------------------------------------------------------------------
-- v_streamassist_state
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_streamassist_state` AS
SELECT TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  COALESCE(JSON_VALUE(json_payload,'$.response.answer.state'),'UNKNOWN') AS state, COUNT(*) AS n
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs` WHERE log_name LIKE '%gemini_enterprise_user_activity' AND JSON_VALUE(json_payload,'$.logMetadata.methodName')='StreamAssist' GROUP BY day, state
;

-- ---------------------------------------------------------------------
-- v_model_armor_block
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_model_armor_block` AS
SELECT TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  JSON_VALUE(json_payload,'$.operationType') AS operation,
  COUNTIF(JSON_VALUE(json_payload,'$.sanitizationResult.filterMatchState')='MATCH_FOUND') AS blocked,
  COUNT(*) AS inspected,
  ROUND(SAFE_DIVIDE(COUNTIF(JSON_VALUE(json_payload,'$.sanitizationResult.filterMatchState')='MATCH_FOUND'),COUNT(*))*100,2) AS block_pct
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs` WHERE log_name LIKE '%sanitize_operations' GROUP BY day, operation
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
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs` WHERE log_name LIKE '%sanitize_operations' GROUP BY day
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
  FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs` WHERE log_name LIKE '%sanitize_operations' GROUP BY day )
 GROUP BY day )
SELECT day, threat_type, threat_count FROM base
UNPIVOT(threat_count FOR threat_type IN (dangerous,harassment,hate_speech,sexually_explicit,csam,prompt_injection))
;

-- ---------------------------------------------------------------------
-- v_hourly_heatmap
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_hourly_heatmap` AS
SELECT FORMAT_TIMESTAMP('%A', timestamp) AS weekday, EXTRACT(HOUR FROM timestamp) AS hour_of_day, COUNT(*) AS queries
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs` WHERE log_name LIKE '%gemini_enterprise_user_activity' AND JSON_VALUE(json_payload,'$.logMetadata.methodName') IN ('Search','StreamAssist') GROUP BY weekday, hour_of_day
;

-- ---------------------------------------------------------------------
-- v_agent_usage_daily
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_agent_usage_daily` AS
SELECT TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  JSON_VALUE(resource.labels,'$.agent_id') AS agent_id,
  COUNT(*) AS user_turns
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs` WHERE log_name LIKE '%gen_ai.user.message'
GROUP BY day, agent_id
;

-- ---------------------------------------------------------------------
-- v_response_latency_daily
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_response_latency_daily` AS
WITH g AS (
  SELECT trace, JSON_VALUE(resource.labels,'$.agent_id') AS agent_id,
    JSON_VALUE(labels,'$."event.name"') AS ev, timestamp
  FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs`
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
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs`,
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
  FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs`
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
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs`
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
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs` WHERE log_name LIKE '%sanitize_operations'
GROUP BY day, client_name, operation, template_id
;

-- ---------------------------------------------------------------------
-- v_user_agent_trace
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_user_agent_trace` AS
WITH ua AS (
  SELECT trace, MAX(JSON_VALUE(json_payload,'$.userIamPrincipal')) user_id
  FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs` WHERE log_name LIKE '%gemini_enterprise_user_activity' AND trace IS NOT NULL GROUP BY trace ),
ga AS (
  SELECT trace,
    MAX(JSON_VALUE(resource.labels,'$.agent_id')) agent_id,
    MAX(IF(JSON_VALUE(labels,'$."event.name"')='gen_ai.user.message',timestamp,NULL)) req_ts,
    MAX(IF(JSON_VALUE(labels,'$."event.name"')='gen_ai.choice',timestamp,NULL)) resp_ts
  FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs` WHERE log_name LIKE '%2Fgen_ai%' AND trace IS NOT NULL GROUP BY trace )
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
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs` WHERE log_name LIKE '%sanitize_operations'
GROUP BY day, operation
;
