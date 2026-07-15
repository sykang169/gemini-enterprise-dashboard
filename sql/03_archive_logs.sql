-- =============================================================================
-- ③ Log archive — durable copy of the dashboard's source logs
-- =============================================================================
--
-- WHY THIS EXISTS
-- ---------------
-- gemini_ent_analytics._AllLogs is a LINKED dataset: a VIEW over the _Default
-- Cloud Logging bucket, storing 0 bytes of its own. That is what makes the
-- dashboard free to run (no BigQuery storage, always fresh), but it also means
-- the log bucket's retention IS the dashboard's memory. When retention expires
-- (30 days by default), the rows vanish from _AllLogs too. There is no
-- backfill.
--
-- This script keeps a real, partitioned BigQuery table with the SAME SCHEMA as
-- _AllLogs, so history survives retention expiry and every existing v_* view
-- can read it without a rewrite.
--
-- WHAT IT ARCHIVES, AND WHY NOT EVERYTHING
-- ----------------------------------------
-- Measured on the source project over 38 days (7.3M rows / 20.6 GB total):
--
--   log source                     rows      size     archived?
--   ----------------------------   -------   ------   ---------
--   unrelated logs (Cloud Run...)  6.5M      15.1 GB  NO  - no view reads them
--   Model Armor, client=VERTEX_AI  765,875    5.5 GB  NO  - see below
--   Model Armor, client=GEMINI_*   527        2.3 MB  YES - the real user prompts
--   gen_ai (latency, agents)       2,927      7.0 MB  YES
--   user_activity (core signal)    369        1.4 MB  YES
--   api_errors                     4          ~0      YES
--
-- Filtering this way turns a 20.6 GB/38d archive into ~11 MB/38d — the storage
-- cost rounds to zero — while keeping every row any dashboard view consumes.
--
-- *** THE MODEL ARMOR client_name FILTER IS NOT AN OPTIMIZATION — IT IS A ***
-- *** CORRECTNESS FIX. ***
-- A project-wide Model Armor floor setting intercepts EVERY Vertex AI call in
-- the project, including this dashboard's own ML.GENERATE_TEXT content
-- classification (sql/02). Those self-generated calls are logged as
-- sanitize_operations with client_name=VERTEX_AI, and they dwarf real user
-- traffic 99.93% to 0.07%. Worse, when classification ran over the MA logs it
-- classified its own prompts, and each pass logged more rows to classify:
--
--   2026-07-09    7,479 self-traffic rows / 0 real user prompts
--   2026-07-10   22,169 / 0
--   2026-07-11   70,386 / 0
--   2026-07-12  233,409 / 0
--   2026-07-13  420,692 / 0      <- ~3x per day, compounding
--   2026-07-14      445 / 335    <- loop cut (sql/02 source -> user_activity)
--
-- Archiving on client_name LIKE 'GEMINI_ENTERPRISE%' keeps the loop's exhaust
-- out of the permanent record. Do not relax this filter to "all MA logs".
--
-- DEDUPLICATION
-- -------------
-- Key = (log_name, timestamp, insert_id). Verified against 7.3M live rows:
--   - insert_id ALONE IS NOT UNIQUE: 7,887 ids repeat (132,789 rows), mostly
--     reused across different timestamps (7,849) and log_names (2,524).
--     Deduping on insert_id alone would silently delete distinct events.
--   - The 3-column key collides on only 38 keys (76 rows), and in all 38 the
--     colliding rows are byte-identical — true duplicates that SHOULD collapse.
--   - Cloud Logging's `split` field is never populated here (0 of 7.3M), so no
--     entry is chunked across rows.
-- MERGE on that key makes re-runs idempotent: an interrupted or double-fired
-- schedule re-reads the same window and inserts nothing.
--
-- LATE ARRIVALS
-- -------------
-- Logs can land in the bucket after their event timestamp, so a strict
-- "timestamp > MAX(archived)" watermark would skip stragglers permanently.
-- Each run therefore re-scans a lookback window behind the watermark and lets
-- the MERGE key absorb what it already has.
-- =============================================================================

-- Normally a no-op: sql/01 already creates this table (empty) so that
-- v_log_source can reference it unconditionally even when archiving is off.
-- It is repeated here so this script also stands alone -- run straight via
-- `bq query` against a dataset built before v_log_source existed and it still
-- works. `WHERE FALSE` copies _AllLogs' exact schema (27 columns incl.
-- RECORD/JSON types) without copying rows, keeping the archive structurally
-- identical to the linked view so `INSERT ROW` below stays valid. Partitioned
-- by day so the MERGE and the views prune; clustered by log_name because
-- every view filters on it.
CREATE TABLE IF NOT EXISTS `YOUR_PROJECT_ID.gemini_ent_dashboard.t_logs_archive`
PARTITION BY DATE(timestamp)
CLUSTER BY log_name
OPTIONS (
  description = "Durable copy of the dashboard's source logs, surviving _Default bucket retention. Filtered to logs the v_* views actually read; Model Armor rows are limited to client_name LIKE 'GEMINI_ENTERPRISE%' to exclude this project's own Vertex AI traffic. Append-only, deduped on (log_name, timestamp, insert_id). See sql/03_archive_logs.sql."
)
AS SELECT * FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs` WHERE FALSE;

-- Everything below runs inside BEGIN/END for one specific reason: BigQuery
-- only accepts DECLARE at the start of a script OR at the start of a block,
-- and the watermark cannot be declared at the top of the script because it
-- reads the archive table, which does not exist until the CREATE TABLE above
-- has run. Wrapping the MERGE in a block gives the declarations a legal home
-- after the table is guaranteed to exist.
BEGIN

-- Watermark: newest row already archived. On the very first run the archive is
-- empty, so this falls back to the epoch and the MERGE backfills whatever the
-- bucket still holds (i.e. everything inside the current retention window).
DECLARE watermark TIMESTAMP DEFAULT (
  SELECT COALESCE(MAX(timestamp), TIMESTAMP("1970-01-01"))
  FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.t_logs_archive`
);

-- Re-scan this far behind the watermark to catch late-arriving entries. The
-- MERGE key means re-reading rows is free of side effects.
DECLARE lookback TIMESTAMP DEFAULT TIMESTAMP_SUB(watermark, INTERVAL 2 DAY);

MERGE `YOUR_PROJECT_ID.gemini_ent_dashboard.t_logs_archive` T
USING (
  SELECT *
  FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs`
  WHERE timestamp >= lookback
    AND (
      -- Gemini Enterprise: user_activity (questions/answers), gen_ai
      -- (latency, agent attribution), api_errors (KB indexing failures).
      log_name LIKE "%gemini_enterprise_user_activity"
      OR log_name LIKE "%gen_ai.user.message"
      OR log_name LIKE "%gen_ai.choice"
      OR log_name LIKE "%api_errors"
      -- Model Armor: real end-user prompts only. See the header — VERTEX_AI
      -- rows are this dashboard's own classification traffic.
      OR (
        log_name LIKE "%sanitize_operations"
        AND JSON_VALUE(labels, "$.\"modelarmor.googleapis.com/client_name\"") LIKE "GEMINI_ENTERPRISE%"
      )
    )
  -- Collapse byte-identical duplicates inside the batch before the MERGE sees
  -- them: MERGE raises if two source rows match the same target row.
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY log_name, timestamp, insert_id
    ORDER BY receive_timestamp
  ) = 1
) S
-- The T.timestamp bound is what lets BigQuery prune the archive's partitions
-- instead of scanning the whole table on every run. Keep it first.
ON  T.timestamp >= lookback
AND T.log_name  = S.log_name
AND T.timestamp = S.timestamp
AND T.insert_id = S.insert_id
WHEN NOT MATCHED THEN INSERT ROW;

END;
