-- =====================================================================
-- Gemini Enterprise + Model Armor — Log Analytics 대시보드 쿼리 세트
-- =====================================================================
-- 대상 테이블 (Log Analytics linked dataset / _AllLogs):
--   `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs`
--
-- 사용법:
--   Cloud Console → Logging → Log Analytics → 아래 쿼리 실행 →
--   [차트] 탭에서 시각화 → [대시보드에 저장] 으로 패널 추가.
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
