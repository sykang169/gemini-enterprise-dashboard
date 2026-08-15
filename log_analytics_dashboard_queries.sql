-- =====================================================================
-- Gemini Enterprise + Model Armor — Log Analytics 대시보드 쿼리 세트
-- =====================================================================
-- 대상 테이블 — 실행하는 창구에 따라 FROM 이름이 다릅니다(같은 데이터):
--   BigQuery 콘솔 / bq CLI (아래 쿼리들의 기본형, BQ 스캔 요금 있음)
--     `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs`        ← 링크된 데이터셋
--   Log Analytics 콘솔 (무료)
--     `YOUR_PROJECT_ID.global._Default._AllLogs`             ← 로그 뷰 4단 경로
--       형식: <프로젝트ID>.<버킷 위치>.<버킷ID>.<뷰ID>
--       (`gcloud logging buckets list` 의 LOCATION/BUCKET_ID)
--     ※ 링크된 데이터셋 이름을 여기 쓰면
--       "FROM clause must contain exactly one log view" 오류가 납니다.
--     ※ Log Analytics 는 FROM 에 로그 뷰 1개만 허용합니다 —
--       13) 처럼 뷰를 두 번 참조하는 CTE 조인은 BigQuery 쪽에서 실행하세요.
--
-- 사용법:
--   Cloud Console → Logging → Log Analytics → 아래 쿼리 실행 →
--   [차트] 탭에서 시각화 → [대시보드에 저장] 으로 패널 추가.
--   바로가기: https://console.cloud.google.com/logs/analytics?project=YOUR_PROJECT_ID
--
-- 주의(중요):
--   Log Analytics는 활성화 시점(2026-07-08 이후) 로그부터 인덱싱됩니다.
--   과거 로그는 Logs Explorer(classic)에서 조회하세요. 시계열은 지금부터 누적됩니다.
--
-- 필드 매핑 요약:
--   사용자      = json_payload.userIamPrincipal
--   호출유형    = json_payload.logMetadata.methodName (Search / StreamAssist / WriteUserEvent / UploadSessionFile)
--   에이전트호출 = methodName = 'StreamAssist'
--   실제 쿼리   = methodName IN ('Search','StreamAssist')  (WriteUserEvent/UploadSessionFile 제외)
--   성공상태    = json_payload.response.answer.state ('SUCCEEDED')
--   실패        = severity IN ('ERROR','CRITICAL','ALERT','EMERGENCY')
--   Model Armor 차단 = json_payload.sanitizationResult.filterMatchState = 'MATCH_FOUND'
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) 일별 쿼리 수 (전체)
-- ---------------------------------------------------------------------
SELECT
  TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  COUNT(*) AS queries
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs`
WHERE log_name LIKE '%gemini_enterprise_user_activity'
  AND JSON_VALUE(json_payload, '$.logMetadata.methodName') IN ('Search', 'StreamAssist')
GROUP BY day
ORDER BY day;


-- ---------------------------------------------------------------------
-- 2) 일별 쿼리 수 — 호출 유형별 (Search vs StreamAssist)  [누적/그룹 막대]
-- ---------------------------------------------------------------------
SELECT
  TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  JSON_VALUE(json_payload, '$.logMetadata.methodName') AS method,
  COUNT(*) AS calls
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs`
WHERE log_name LIKE '%gemini_enterprise_user_activity'
  AND JSON_VALUE(json_payload, '$.logMetadata.methodName') IN ('Search', 'StreamAssist')
GROUP BY day, method
ORDER BY day, method;


-- ---------------------------------------------------------------------
-- 3) 일별 에이전트(StreamAssist) 호출 수
-- ---------------------------------------------------------------------
SELECT
  TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  COUNT(*) AS agent_calls
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs`
WHERE log_name LIKE '%gemini_enterprise_user_activity'
  AND JSON_VALUE(json_payload, '$.logMetadata.methodName') = 'StreamAssist'
GROUP BY day
ORDER BY day;


-- ---------------------------------------------------------------------
-- 4) 사용자당 쿼리 수 (Top 50)  [가로 막대]
-- ---------------------------------------------------------------------
SELECT
  JSON_VALUE(json_payload, '$.userIamPrincipal') AS user_id,
  COUNTIF(JSON_VALUE(json_payload, '$.logMetadata.methodName') = 'StreamAssist') AS agent_calls,
  COUNTIF(JSON_VALUE(json_payload, '$.logMetadata.methodName') = 'Search')       AS searches,
  COUNT(*) AS total_queries
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs`
WHERE log_name LIKE '%gemini_enterprise_user_activity'
  AND JSON_VALUE(json_payload, '$.logMetadata.methodName') IN ('Search', 'StreamAssist')
GROUP BY user_id
ORDER BY total_queries DESC
LIMIT 50;


-- ---------------------------------------------------------------------
-- 5) 일별 활성 사용자 수 (DAU) 및 사용자당 평균 쿼리
-- ---------------------------------------------------------------------
SELECT
  TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  COUNT(DISTINCT JSON_VALUE(json_payload, '$.userIamPrincipal')) AS active_users,
  COUNT(*) AS queries,
  ROUND(SAFE_DIVIDE(COUNT(*), COUNT(DISTINCT JSON_VALUE(json_payload, '$.userIamPrincipal'))), 2) AS queries_per_user
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs`
WHERE log_name LIKE '%gemini_enterprise_user_activity'
  AND JSON_VALUE(json_payload, '$.logMetadata.methodName') IN ('Search', 'StreamAssist')
GROUP BY day
ORDER BY day;


-- ---------------------------------------------------------------------
-- 6) 일별 실패율 (severity 기반)  [실패율 선 그래프 + total 막대]
-- ---------------------------------------------------------------------
SELECT
  TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  COUNTIF(severity IN ('ERROR', 'CRITICAL', 'ALERT', 'EMERGENCY')) AS failures,
  COUNT(*) AS total,
  ROUND(SAFE_DIVIDE(
    COUNTIF(severity IN ('ERROR', 'CRITICAL', 'ALERT', 'EMERGENCY')),
    COUNT(*)) * 100, 2) AS failure_pct
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs`
WHERE log_name LIKE '%gemini_enterprise_user_activity'
GROUP BY day
ORDER BY day;


-- ---------------------------------------------------------------------
-- 7) StreamAssist 성공/실패 상태 분포 (answer.state 기반)
-- ---------------------------------------------------------------------
SELECT
  TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  COALESCE(JSON_VALUE(json_payload, '$.response.answer.state'), 'UNKNOWN') AS state,
  COUNT(*) AS n
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs`
WHERE log_name LIKE '%gemini_enterprise_user_activity'
  AND JSON_VALUE(json_payload, '$.logMetadata.methodName') = 'StreamAssist'
GROUP BY day, state
ORDER BY day, state;


-- ---------------------------------------------------------------------
-- 8) Model Armor — 일별 검사 건수 및 차단(MATCH_FOUND) 비율
--    (프롬프트 검사 vs 응답 검사 구분)
-- ---------------------------------------------------------------------
SELECT
  TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  JSON_VALUE(json_payload, '$.operationType') AS operation,
  COUNTIF(JSON_VALUE(json_payload, '$.sanitizationResult.filterMatchState') = 'MATCH_FOUND') AS blocked,
  COUNT(*) AS inspected,
  ROUND(SAFE_DIVIDE(
    COUNTIF(JSON_VALUE(json_payload, '$.sanitizationResult.filterMatchState') = 'MATCH_FOUND'),
    COUNT(*)) * 100, 2) AS block_pct
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs`
WHERE log_name LIKE '%sanitize_operations'
GROUP BY day, operation
ORDER BY day, operation;


-- ---------------------------------------------------------------------
-- 9) Model Armor — 위협 유형별 탐지 건수 (RAI + CSAM)  [파이/막대]
-- ---------------------------------------------------------------------
SELECT
  TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  COUNTIF(JSON_VALUE(json_payload, '$.sanitizationResult.filterResults.rai.raiFilterResult.raiFilterTypeResults.dangerous.matchState')        = 'MATCH_FOUND') AS dangerous,
  COUNTIF(JSON_VALUE(json_payload, '$.sanitizationResult.filterResults.rai.raiFilterResult.raiFilterTypeResults.harassment.matchState')       = 'MATCH_FOUND') AS harassment,
  COUNTIF(JSON_VALUE(json_payload, '$.sanitizationResult.filterResults.rai.raiFilterResult.raiFilterTypeResults.hate_speech.matchState')      = 'MATCH_FOUND') AS hate_speech,
  COUNTIF(JSON_VALUE(json_payload, '$.sanitizationResult.filterResults.rai.raiFilterResult.raiFilterTypeResults.sexually_explicit.matchState') = 'MATCH_FOUND') AS sexually_explicit,
  COUNTIF(JSON_VALUE(json_payload, '$.sanitizationResult.filterResults.csam.csamFilterFilterResult.matchState')                                = 'MATCH_FOUND') AS csam
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs`
WHERE log_name LIKE '%sanitize_operations'
GROUP BY day
ORDER BY day;


-- ---------------------------------------------------------------------
-- 10) 시간대별 트래픽 히트맵 (요일 x 시각)  [히트맵/막대]
-- ---------------------------------------------------------------------
SELECT
  FORMAT_TIMESTAMP('%A', timestamp) AS weekday,
  EXTRACT(HOUR FROM timestamp)      AS hour_of_day,
  COUNT(*) AS queries
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs`
WHERE log_name LIKE '%gemini_enterprise_user_activity'
  AND JSON_VALUE(json_payload, '$.logMetadata.methodName') IN ('Search', 'StreamAssist')
GROUP BY weekday, hour_of_day
ORDER BY hour_of_day;


-- =====================================================================
-- 토큰 사용량 (Gemini Enterprise LLM 호출)
-- ---------------------------------------------------------------------
-- 소스 로그: discoveryengine.googleapis.com/gen_ai.client.inference.operation.details
--   (어시스턴트가 LLM을 호출할 때마다 1건. 필드는 JSON 키 자체에 점이 있으므로
--    반드시 따옴표 경로 `$."gen_ai.usage.input_tokens"` 로 써야 합니다.)
--
-- 읽는 법:
--   cached_input_tokens 는 input_tokens 에 "포함된" 부분집합(시스템 프롬프트·툴
--   정의 캐시분)입니다. 절대 더하지 마세요. 총합 = input + output.
--   캐시분은 무료가 아니라 할인 단가라, 실제 비용은
--   uncached_input_tokens ~ input_tokens 사이에 있습니다.
--
-- 빠지는 것(= 청구서와 다를 수 있는 이유):
--   ① Model Armor 에 차단된 턴은 이 로그가 아예 안 남습니다(생성은 이미 돌아 토큰은 소모됨).
--   ② 응답 스트림을 중간에 끊으면 input_tokens=0 으로 기록됩니다.
--   ③ Search 는 생성이 없어 행이 없습니다(StreamAssist 만 잡힘).
--   ④ 모델명은 이 로그에 없습니다(Cloud Trace 의 generate_content span 에만 존재).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 11) 최근 90일 토큰 총합 (한 행)  [스코어카드]
-- ---------------------------------------------------------------------
SELECT
  COUNT(*)                  AS llm_calls,
  COUNT(DISTINCT trace)     AS turns,
  SUM(SAFE_CAST(JSON_VALUE(json_payload,'$."gen_ai.usage.input_tokens"')            AS INT64)) AS input_tokens,
  SUM(SAFE_CAST(JSON_VALUE(json_payload,'$."gen_ai.usage.cache_read.input_tokens"') AS INT64)) AS cached_input_tokens,
  SUM(SAFE_CAST(JSON_VALUE(json_payload,'$."gen_ai.usage.input_tokens"')            AS INT64)
      - COALESCE(SAFE_CAST(JSON_VALUE(json_payload,'$."gen_ai.usage.cache_read.input_tokens"') AS INT64), 0)) AS uncached_input_tokens,
  SUM(SAFE_CAST(JSON_VALUE(json_payload,'$."gen_ai.usage.output_tokens"')           AS INT64)) AS output_tokens,
  SUM(SAFE_CAST(JSON_VALUE(json_payload,'$."gen_ai.usage.input_tokens"')            AS INT64)
      + COALESCE(SAFE_CAST(JSON_VALUE(json_payload,'$."gen_ai.usage.output_tokens"') AS INT64), 0)) AS total_tokens,
  MIN(timestamp) AS first_row,
  MAX(timestamp) AS last_row
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
  AND log_name LIKE '%gen_ai.client.inference.operation.details';


-- ---------------------------------------------------------------------
-- 12) 최근 90일 토큰 — 일별 추이  [콤보: 막대=input/output, 선=llm_calls]
-- ---------------------------------------------------------------------
SELECT
  TIMESTAMP_TRUNC(timestamp, DAY) AS day,
  COUNT(*) AS llm_calls,
  SUM(SAFE_CAST(JSON_VALUE(json_payload,'$."gen_ai.usage.input_tokens"')            AS INT64)) AS input_tokens,
  SUM(SAFE_CAST(JSON_VALUE(json_payload,'$."gen_ai.usage.cache_read.input_tokens"') AS INT64)) AS cached_input_tokens,
  SUM(SAFE_CAST(JSON_VALUE(json_payload,'$."gen_ai.usage.output_tokens"')           AS INT64)) AS output_tokens,
  SUM(SAFE_CAST(JSON_VALUE(json_payload,'$."gen_ai.usage.input_tokens"')            AS INT64)
      + COALESCE(SAFE_CAST(JSON_VALUE(json_payload,'$."gen_ai.usage.output_tokens"') AS INT64), 0)) AS total_tokens
FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
  AND log_name LIKE '%gen_ai.client.inference.operation.details'
GROUP BY day
ORDER BY day;


-- ---------------------------------------------------------------------
-- 13) 최근 90일 토큰 — 사용자별 Top N  [가로 막대]
-- ---------------------------------------------------------------------
-- 이 로그의 `user.id` 필드는 모든 행이 리터럴 "user" 라 쓸 수 없습니다.
-- 신원은 user_activity 쪽 userIamPrincipal 에만 있고, 두 로그는 `trace` 로 이어집니다.
-- 전제조건: 엔진에 observabilityConfig.sensitiveLoggingEnabled = true
--           (꺼져 있으면 토큰 수치는 맞되 user_id 가 전부 '<elided>' 한 명으로 뭉칩니다)
WITH tok AS (
  SELECT trace,
    SAFE_CAST(JSON_VALUE(json_payload,'$."gen_ai.usage.input_tokens"')  AS INT64) AS in_tok,
    SAFE_CAST(JSON_VALUE(json_payload,'$."gen_ai.usage.output_tokens"') AS INT64) AS out_tok
  FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs`
  WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
    AND log_name LIKE '%gen_ai.client.inference.operation.details'
    AND trace IS NOT NULL
),
ua AS (
  -- trace 당 1행으로 접어야 합니다. 같은 trace 에 ModelArmorAudit 행이 따라붙는
  -- 경우가 있어, DISTINCT 없이 조인하면 토큰이 그 배수만큼 부풀려집니다.
  SELECT trace, MAX(JSON_VALUE(json_payload,'$.userIamPrincipal')) AS user_id
  FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs`
  WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
    AND log_name LIKE '%gemini_enterprise_user_activity'
    AND JSON_VALUE(json_payload,'$.logMetadata.methodName') = 'StreamAssist'
    AND trace IS NOT NULL
  GROUP BY trace
)
SELECT
  ua.user_id,
  COUNT(DISTINCT tok.trace) AS turns,
  SUM(tok.in_tok)  AS input_tokens,
  SUM(tok.out_tok) AS output_tokens,
  SUM(tok.in_tok + COALESCE(tok.out_tok, 0)) AS total_tokens
FROM tok LEFT JOIN ua USING (trace)
GROUP BY user_id
ORDER BY total_tokens DESC;
