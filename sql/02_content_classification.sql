-- =====================================================================
-- ② 콘텐츠 인텔리전스 — BigQuery + Gemini 로 사용자 질문 토픽/의도/감성 분류
-- =====================================================================
-- 소스: gemini_enterprise_user_activity 로그의 사용자 질문 원문
--   (Search=$.request.query, StreamAssist=$.request.query.parts[].text) — 쿼리 1건=1행.
--   ※과거엔 MA sanitize 로그(sanitizationInput.text)를 썼으나, 스트리밍/부분검사로
--     한 질문이 수천 건으로 부풀려져 Gemini 호출이 폭증(비용). user_activity는 중복이
--     없어 분류 대상이 ~100배 감소하고 실제 질문만 분류돼 품질도 향상.
--     단 user_activity는 engine observabilityConfig.sensitiveLoggingEnabled=true 이후
--     로그부터 원문(그 전엔 <elided> 마스킹 → WHERE로 제외). 기존 t_content_topics의
--     MA기반 과거 분류(그 이전 날짜)는 그대로 보존(파생 라벨이라 소스 무관).
-- 설계 원칙(프라이버시): 원문 텍스트는 저장하지 않고 '파생 라벨'(topic/intent/sentiment)만 저장.
-- 선행 조건: BQ 연결 `us.gemini_conn` + 원격 모델 `gemini_ent_dashboard.gemini_flash`.
-- 비용: 분류 대상 행당 Gemini 호출 1회. 재분류 방지를 위해 이미 분류된 timestamp는 제외(증분).
-- =====================================================================

-- 1) 분류 결과 테이블 (증분 append). 최초 실행 시 생성.
CREATE TABLE IF NOT EXISTS `YOUR_PROJECT_ID.gemini_ent_dashboard.t_content_topics` (
  timestamp TIMESTAMP,
  day       TIMESTAMP,
  topic     STRING,
  intent    STRING,
  sentiment STRING
);

-- 2) 아직 분류 안 된 신규 프롬프트만 분류하여 append
INSERT INTO `YOUR_PROJECT_ID.gemini_ent_dashboard.t_content_topics`
SELECT
  timestamp, day,
  JSON_VALUE(SAFE.PARSE_JSON(txt), '$.topic')     AS topic,
  JSON_VALUE(SAFE.PARSE_JSON(txt), '$.intent')    AS intent,
  JSON_VALUE(SAFE.PARSE_JSON(txt), '$.sentiment') AS sentiment
FROM (
  SELECT day, timestamp,
    -- 코드펜스 제거 후 순수 JSON만 남김
    REGEXP_REPLACE(ml_generate_text_llm_result, r'(?i)^\s*```(json)?|```\s*$', '') AS txt
  FROM ML.GENERATE_TEXT(
    MODEL `YOUR_PROJECT_ID.gemini_ent_dashboard.gemini_flash`,
    (
      SELECT day, timestamp,
        CONCAT(
          '너는 기업용 AI 어시스턴트 로그 분석기다. 다음 사용자 질문을 분류해 JSON 한 줄만 출력하라. ',
          '형식: {"topic":"<주제 대분류 한국어 한 단어, 예: 보험/법률/날씨/HR/IT/일반>",',
          '"intent":"질문|요청|잡담|불만|기타",',
          '"sentiment":"긍정|중립|부정"}. ',
          '설명 없이 JSON만. 질문: ',
          SUBSTR(question_text, 1, 2000)          -- 초장문 방어(토큰 상한)
        ) AS prompt
      FROM (
        SELECT
          TIMESTAMP_TRUNC(timestamp, DAY) AS day,
          timestamp,
          -- user_activity 질문 원문: Search=$.request.query(스칼라),
          -- StreamAssist=$.request.query.parts[].text(객체). 1건=1행(중복 없음).
          COALESCE(
            JSON_VALUE(json_payload, '$.request.query'),
            (SELECT STRING_AGG(JSON_VALUE(p, '$.text'), '\n')
               FROM UNNEST(JSON_QUERY_ARRAY(json_payload, '$.request.query.parts')) p
               WHERE JSON_VALUE(p, '$.text') IS NOT NULL)
          ) AS question_text
        FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs`
        WHERE log_name LIKE '%gemini_enterprise_user_activity'
          AND JSON_VALUE(json_payload, '$.logMetadata.methodName') IN ('Search','StreamAssist')
          AND timestamp > COALESCE(
            (SELECT MAX(timestamp) FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.t_content_topics`),
            TIMESTAMP('1970-01-01'))
      )
      -- 마스킹(<elided>)·빈 질문 제외 → Gemini 호출 낭비 방지
      WHERE question_text IS NOT NULL
        AND question_text != '<elided>'
    ),
    STRUCT(TRUE AS flatten_json_output, 0.0 AS temperature, 100 AS max_output_tokens)
  )
);

-- 3) 집계 뷰: 토픽 분포
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_topic_distribution` AS
SELECT day, topic, COUNT(*) AS n
FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.t_content_topics`
WHERE topic IS NOT NULL
GROUP BY day, topic;

-- 4) 집계 뷰: 의도 분포
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_intent_distribution` AS
SELECT day, intent, COUNT(*) AS n
FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.t_content_topics`
WHERE intent IS NOT NULL
GROUP BY day, intent;

-- 5) 집계 뷰: 일별 감성 (불만/부정 비율 모니터링)
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.gemini_ent_dashboard.v_sentiment_daily` AS
SELECT day,
  COUNTIF(sentiment='긍정') AS positive,
  COUNTIF(sentiment='중립') AS neutral,
  COUNTIF(sentiment='부정') AS negative,
  ROUND(SAFE_DIVIDE(COUNTIF(sentiment='부정'), COUNT(*))*100, 2) AS negative_pct
FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.t_content_topics`
GROUP BY day;
