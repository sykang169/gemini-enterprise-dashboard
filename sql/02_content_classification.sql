-- =====================================================================
-- ② 콘텐츠 인텔리전스 — BigQuery + Gemini 로 사용자 질문 토픽/의도/감성 분류
-- =====================================================================
-- 소스: gemini_enterprise_user_activity 로그의 사용자 질문 원문
--   (Search=$.request.query, StreamAssist=$.request.query.parts[].text) — 쿼리 1건=1행.
--   ※과거엔 MA sanitize 로그(sanitizationInput.text)를 썼으나, 스트리밍/부분검사로
--     한 질문이 수천 건으로 부풀려져 Gemini 호출이 폭증(비용). user_activity는 중복이
--     없어 분류 대상이 ~100배 감소하고 실제 질문만 분류돼 품질도 향상.
--     단 user_activity는 engine observabilityConfig.sensitiveLoggingEnabled=true 이후
--     로그부터 원문(그 전엔 <elided> 마스킹 → WHERE로 제외).
--   ※MA기반 과거 분류는 2026-07-15에 삭제했다. 한때 "파생 라벨이라 소스 무관"이라며
--     보존했으나, 실측해보니 보존할 값이 아니었다: 173,948행 중 173,837행(99.9%)이
--     MA sanitize 이벤트 기반이었고 실제 질문과 대응되는 행은 72건뿐이었다. 즉
--     토픽/의도/감성 분포가 '질문의 분포'가 아니라 '스트리밍 검사 조각의 분포'였다.
--     라벨이 파생값인 건 맞지만 무엇에서 파생됐는지가 통계의 의미를 정한다.
-- 설계 원칙(프라이버시): 원문 텍스트는 저장하지 않고 '파생 라벨'(topic/intent/sentiment)만 저장.
-- 선행 조건: BQ 연결 `us.gemini_conn` + 원격 모델 `gemini_ent_dashboard.gemini_flash`.
-- 비용: 분류 대상 행당 Gemini 호출 1회. 이미 분류된 timestamp는 anti-join으로 제외하고
--   (아래 2번 참고), 실행이 겹쳐도 MERGE로 중복 INSERT를 막는다.
-- =====================================================================

-- 1) 분류 결과 테이블 (증분 append). 최초 실행 시 생성.
CREATE TABLE IF NOT EXISTS `YOUR_PROJECT_ID.gemini_ent_dashboard.t_content_topics` (
  timestamp TIMESTAMP,
  day       TIMESTAMP,
  topic     STRING,
  intent    STRING,
  sentiment STRING
);

-- 2) 아직 분류 안 된 질문만 분류하여 반영
--
-- *** 워터마크가 아니라 anti-join이다 — 실측으로 확인한 이유 ***
-- 예전엔 `timestamp > (SELECT MAX(timestamp) FROM t_content_topics)` 였다.
-- 이 방식은 "이미 분류된 것을 제외"하는 게 아니라 "가장 최근 분류 시각보다
-- 미래의 것만" 본다. 둘은 다르다:
--   - 워터마크를 한 번 넘긴 뒤 도착한 로그(늦게 들어온 로그)는 영원히 분류되지
--     않는다. 되돌릴 방법도 없다.
--   - 잘못된 소스로 분류한 행을 지워도 워터마크는 남은 행 중 최신값이 정하므로
--     내려가지 않는다. 즉 소스를 고쳐도 과거 질문을 다시 채울 수 없다.
-- 2026-07-15 실측: 분류 가능한 질문 112건 중 72건만 분류되고 40건이 워터마크에
-- 막혀 영구히 누락된 상태였다. 지금은 이미 분류된 timestamp만 제외하므로
-- (파일 상단 주석이 원래 말하던 그 동작), 누락분은 다음 실행에서 자동으로 채워진다.
--
-- *** INSERT가 아니라 MERGE인 이유 ***
-- 증분 조건은 쿼리 시작 시점에 평가된다. 분류 실행은 Gemini 호출 때문에 길다
-- (실측 평균 87분). 그 사이 두 번째 실행이 시작되면 — 스케줄 쿼리와 apply마다
-- 도는 run_content_classification(job_id가 timestamp 기반이라 매번 새로 실행)이
-- 겹칠 수 있다 — 둘 다 같은 "미분류" 집합을 보고 같은 질문을 두 번 분류해
-- 중복 행을 넣는다. 2026-07-15에 실제로 2배 중복이 났다.
-- MERGE ... ON timestamp 로 두면 나중에 끝난 쪽의 중복 INSERT가 무시되어
-- 실행이 겹쳐도 timestamp당 1행이 유지된다(멱등).
MERGE `YOUR_PROJECT_ID.gemini_ent_dashboard.t_content_topics` T
USING (
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
        FROM `YOUR_PROJECT_ID.gemini_ent_analytics._AllLogs` a
        WHERE log_name LIKE '%gemini_enterprise_user_activity'
          AND JSON_VALUE(json_payload, '$.logMetadata.methodName') IN ('Search','StreamAssist')
          -- 이미 분류된 질문 제외. 이 anti-join이 Gemini 호출 앞단에 있어야
          -- 호출 자체가 안 나간다(비용). MERGE의 ON만으로는 결과만 버려질 뿐,
          -- 돈은 이미 쓴 뒤가 된다.
          AND NOT EXISTS (
            SELECT 1 FROM `YOUR_PROJECT_ID.gemini_ent_dashboard.t_content_topics` t
            WHERE t.timestamp = a.timestamp)
      )
      -- 마스킹(<elided>)·빈 질문 제외 → Gemini 호출 낭비 방지
      WHERE question_text IS NOT NULL
        AND question_text != '<elided>'
    ),
    STRUCT(TRUE AS flatten_json_output, 0.0 AS temperature, 100 AS max_output_tokens)
  )
)
) S
ON T.timestamp = S.timestamp
WHEN NOT MATCHED THEN
  INSERT (timestamp, day, topic, intent, sentiment)
  VALUES (S.timestamp, S.day, S.topic, S.intent, S.sentiment);

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
