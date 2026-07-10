# Looker Studio 대시보드 설정 가이드
### Gemini Enterprise + Model Armor 운영·보안 대시보드

데이터 소스: BigQuery → `YOUR_PROJECT_ID` → `gemini_ent_dashboard` → 각 뷰(`v_*`)

---

## 섹션 0. 리포트 생성 + 데이터 연결 (최초 1회)

> **왜 수동인가:** Looker Studio는 "차트가 배치된 리포트"를 코드로 맨바닥에서 만드는 API가 없습니다. 완성형 대시보드를 자동 배포하려면 **템플릿 리포트를 한 번 손으로 만든 뒤**, Linking API로 복제하는 방식뿐입니다(아래 0-C). 그러니 이 섹션은 딱 한 번만 하면 됩니다.

### 0-A. 빈 리포트 만들고 데이터 소스 추가
1. [lookerstudio.google.com](https://lookerstudio.google.com) → **빈 보고서 만들기**
2. **데이터 추가 → BigQuery → `YOUR_PROJECT_ID` → `gemini_ent_dashboard`** 선택
3. 아래 뷰들을 **각각 데이터 소스로 추가**합니다(리포트에 추가 → 계속 추가):
   `v_daily_queries`, `v_daily_queries_by_method`, `v_daily_agent_calls`, `v_queries_per_user`, `v_daily_active_users`, `v_daily_failure_rate`, `v_streamassist_state`, `v_model_armor_block`, `v_model_armor_threats`, `v_model_armor_threats_long`, `v_hourly_heatmap`, `v_agent_usage_daily`, `v_response_latency_daily`, `v_grounding_top_sources`, `v_grounding_coverage_daily`, `v_user_activity_detail`, `v_model_armor_by_client`, `v_user_agent_trace`, `v_model_armor_verdict_daily`
4. 아래 **섹션 A~11** 가이드대로 차트를 배치합니다.

### 0-B. (권장) 데이터 자격증명 검토
데이터 소스는 기본적으로 **소유자(Owner's) 자격증명**입니다 → 공유받은 사람이 BigQuery 권한 없이도 데이터를 봅니다. 로그에 사용자 이메일·질문 내용이 있으니, 광범위 공유 시엔 **Resource → Manage added data sources → 각 소스 Edit → Viewer's credentials**로 바꾸거나 신뢰 대상에게만 공유하세요.

### 0-C. 자동 재배포를 위한 템플릿 등록 (선택, 강력 권장)
이 리포트를 한 번 완성해두면, 다른 프로젝트에는 **완성형 대시보드를 URL 하나로 복제**할 수 있습니다:
1. **각 데이터 소스의 별칭(Alias)을 뷰 이름과 똑같이** 설정합니다.
   Resource → Manage added data sources → **Alias** 열을 `v_daily_queries`, `v_model_armor_block` … 처럼 뷰 이름으로 맞춤. (이 별칭이 자동 생성 URL의 `ds.<alias>`와 일치해야 함)
2. 리포트 URL에서 **report id**를 복사합니다 — `.../reporting/`**`<REPORT_ID>`**`/page/...` 의 가운데 부분.
3. 그 값을 넣어 다시 배포하면 완성형 복제 URL이 출력됩니다:
   ```bash
   terraform -chdir=terraform apply \
     -var="project_id=<TARGET_PROJECT>" \
     -var="looker_studio_template_report_id=<REPORT_ID>"
   # 완료 후:
   terraform -chdir=terraform output -raw looker_studio_url   # 차트까지 완성된 대시보드 복제 링크
   ```
   이 링크를 열면 대상 프로젝트의 뷰로 데이터가 연결된 **완성형 대시보드가 자동 생성**됩니다.

---

> ## 이 대시보드가 Gemini Enterprise 내장 애널리틱스보다 나은 이유
> 일별 쿼리·사용자수 같은 기본 지표는 내장 대시보드가 이미 잘 보여줍니다. **이 대시보드의 진짜 가치는 내장이 안 보여주는 4가지**입니다. 대시보드 상단·별도 페이지에 이걸 강조하세요:
> 1. **🛡️ Model Armor 보안** — 차단율·위협유형(폭력/혐오/성/CSAM). 내장 애널리틱스엔 없음.
> 2. **⚡ 응답 지연시간 (p50/p95)** — SLO 모니터링용. trace로 계산.
> 3. **📚 그라운딩 신뢰도** — 근거 있는 답변 비율·평균 인용 수 = 할루시네이션 리스크 지표.
> 4. **🔗 인용 출처 Top** — 어떤 KB 문서/도메인이 실제 답변에 쓰이는지 = 콘텐츠 활용도.
> 5. **🤖 개별 에이전트별 사용량** — 커스텀 에이전트(agent_id)까지 분해.
>
> 아래 **섹션 A(차별화 지표)** 를 대시보드 첫 페이지로, 기본 지표(섹션 1~11)는 둘째 페이지로 두는 구성을 권장합니다.

---

## 섹션 A. 차별화 지표 (내장 대시보드에 없는 것 — 최우선 배치)

### A-1. 🛡️ Model Armor 보안 (섹션 9·10 재사용)
`v_model_armor_block`(차단율 시계열) + `v_model_armor_threats_long`(위협유형 파이). 아래 9·10·11 항목 참고.

### A-2. ⚡ 응답 지연시간 p50/p95
- **차트**: 시계열(다중 선)
- **데이터 소스**: `v_response_latency_daily`
- **기간 측정기준**: `day`
- **분류(선택)**: `agent_id`
- **측정항목**: `p50_sec`(AVG), `p95_sec`(AVG) — 형식 숫자(초)
- **스코어카드**: `p95_sec` 최근값을 SLO 타일로 (임계 초과 시 빨강)

### A-3. 📚 그라운딩 신뢰도 (할루시네이션 리스크)
- **차트**: 콤보(막대+선)
- **데이터 소스**: `v_grounding_coverage_daily`
- **기간 측정기준**: `day`
- **측정항목**: 막대=`answers`(SUM), 선(오른축)=`grounded_pct`(AVG, 백분율)
- **스코어카드**: `avg_sources_per_answer`(AVG), 전체 근거율 계산필드 `SUM(grounded_answers)/SUM(answers)`

### A-4. 🔗 인용 출처 Top (콘텐츠 활용도)
- **차트**: 가로 막대 또는 트리맵
- **데이터 소스**: `v_grounding_top_sources`
- **측정기준**: `source`
- **측정항목**: `citations`(SUM)
- **정렬**: `citations` 내림차순, 행 수 15
- 참고: 기간필터 필요하면 뷰에 `day` 추가 버전 요청

### A-5. 🤖 개별 에이전트별 사용량
- **차트**: 시계열(누적 막대) 또는 가로 막대
- **데이터 소스**: `v_agent_usage_daily`
- **기간 측정기준**: `day`
- **분류**: `agent_id` (core_assistant + 커스텀 에이전트)
- **측정항목**: `user_turns`(SUM)

### A-6. 👤 사용자별 상세 / 드릴다운 (사용자별 검색)
- **차트**: 표(테이블) — 상호작용 필터용
- **데이터 소스**: `v_user_activity_detail` (쿼리 1건 = 1행)
- **측정기준**: `user_id`, `method`, `day`
- **측정항목**: 레코드 수(Record Count), `source_count`(AVG)
- **필터 컨트롤 추가**: `user_id` 드롭다운 컨트롤 → **특정 사용자만 필터링** 가능 (= 사용자별 검색)
- 활용: 특정 사용자 선택 시 다른 모든 차트가 그 사용자로 필터되게 하려면 `user_id` 컨트롤을 페이지 상단에 배치하고 데이터 소스를 이 뷰로 통일
- ⚠️ 주의: 사용자별 Model Armor 차단은 **불가** (MA 로그에 사용자ID 없음). 사용자별로 얻을 수 있는 건 쿼리/에이전트/그라운딩까지.

### A-7. 🏷️ Model Armor 업무/비업무 분류
- **차트**: 누적 막대 또는 표
- **데이터 소스**: `v_model_armor_by_client`
- **기간 측정기준**: `day`
- **분류**: `client_name` (GEMINI_ENTERPRISE_BUSINESS vs NON_BUSINESS)
- **측정항목**: `inspected`(SUM), `block_pct`(AVG)
- 인사이트: 비업무 트래픽 비중을 파악 → 오·남용 모니터링

### A-8. 🧠 콘텐츠 인텔리전스 (Gemini 분류 — 내장에 절대 없음)
BigQuery+Gemini로 사용자 질문을 분류한 결과. 원문은 저장 안 하고 파생 라벨만 사용(프라이버시).
- **토픽 분포**: 차트=파이/트리맵, 소스=`v_topic_distribution`, 측정기준=`topic`, 측정항목=`n`(SUM)
- **의도 분포**: 차트=막대, 소스=`v_intent_distribution`, 측정기준=`intent`(질문/요청/불만/잡담), 측정항목=`n`(SUM)
- **일별 감성**: 차트=콤보, 소스=`v_sentiment_daily`, 기간=`day`, 막대=`negative`/`neutral`/`positive`, 선=`negative_pct`(AVG) → **불만·부정 급증 조기경보**

---

## 섹션 A 권장 페이지 레이아웃 (Page 1 — 대시보드 첫 화면)

```
┌───────────────────────────────────────────────────────────┐
│ [기간 컨트롤]                                [user_id 컨트롤] │
│ [p95 지연(SLO)] [전체 근거율] [MA 차단율] [부정감성 %]        │ ← 경보 스코어카드
├───────────────────────────────┬───────────────────────────┤
│ A-1 MA 차단율 시계열            │ A-1 위협유형 분포(파이)      │
│  v_model_armor_block           │  v_model_armor_threats_long │
├───────────────────────────────┼───────────────────────────┤
│ A-2 응답지연 p50/p95(선)        │ A-3 그라운딩 신뢰도(콤보)    │
│  v_response_latency_daily      │  v_grounding_coverage_daily │
├───────────────────────────────┼───────────────────────────┤
│ A-4 인용출처 Top(가로막대)       │ A-5 에이전트별 사용량        │
│  v_grounding_top_sources       │  v_agent_usage_daily        │
├───────────────────────────────┴───────────────────────────┤
│ A-8 콘텐츠 인텔리전스: 토픽 파이 | 의도 막대 | 일별 감성 콤보    │
│  v_topic_distribution / v_intent_distribution / v_sentiment_daily │
├───────────────────────────────────────────────────────────┤
│ A-6 사용자별 상세 표(v_user_activity_detail)  |  A-7 MA by client │
└───────────────────────────────────────────────────────────┘
```

Page 2(운영 지표)는 아래 **섹션 B → 권장 페이지 레이아웃** 참고. 두 페이지 구성을 권장합니다.

---

## 🧩 템플릿 필수 체크리스트 (자동 복제가 되려면 반드시)

이 리포트를 `looker_studio_template_report_id`로 재사용하려면, 복제 URL이 넘기는 별칭·데이터소스가 템플릿과 **정확히 일치**해야 합니다.

1. **데이터 소스 = 19개 코어 뷰 전부 추가.** 차트에 안 쓰는 뷰라도 template에 있어야 override가 걸립니다. (코어 뷰 목록은 `terraform output views_created`)
2. **각 데이터 소스 별칭(Alias) = 뷰 이름.** `리소스 → 추가된 데이터 소스 관리 → Alias` 열을 `v_daily_queries` … 처럼 뷰 이름과 **철자까지 동일**하게. (복제 URL의 `ds.<alias>`와 매칭되는 핵심)
3. **페이지마다 기간 컨트롤** 1개씩(자동 복제 후에도 그대로 동작).
4. **크로스필터 켜기**: `파일 → 보고서 설정 → 차트 상호작용 → 필터 적용` 또는 각 차트 `상호작용 → 필터 적용`. 표/컨트롤 클릭이 페이지 전체에 걸리게.
5. **스코어카드 비율은 계산필드**(위 섹션 0의 4번) — 복제해도 계산식이 유지됨.
6. **데이터 최신성 12시간**(각 소스) — 스캔비 절감.
7. 완성 후 **report id 복사** → `-var="looker_studio_template_report_id=<REPORT_ID>"`.

> **A-8(콘텐츠 인텔리전스) 주의:** `v_topic_distribution`·`v_intent_distribution`·`v_sentiment_daily`는 **콘텐츠 분류 옵션(`enable_content_classification=true`)을 켠 프로젝트에만** 존재하고, 자동 복제 override 목록(코어 19개)에는 포함되지 않습니다. A-8을 템플릿에 넣으려면 **템플릿·대상 프로젝트 모두** 분류를 활성화해야 하며, 이 3개 소스는 복제 후 데이터 소스를 수동으로 대상 프로젝트로 바꿔줘야 합니다. (완전 자동을 원하면 A-8은 별도 페이지로 분리하는 것을 권장.)

---

## 섹션 B. 기본 운영 지표 (내장과 겹치지만 커스텀 필터·통합용)

## 0. 공통 준비 (먼저 1회)

1. **데이터 소스 추가**: 보고서에서 `리소스 → 추가된 데이터 소스 관리 → 데이터 추가 → BigQuery`로 필요한 뷰를 각각 추가. (뷰 하나 = 데이터 소스 하나)
2. **`day` 필드 타입 확인**: 각 데이터 소스 편집 화면에서 `day`의 유형이 `날짜 및 시간` 또는 `날짜(YYYYMMDD)`인지 확인. 시계열 X축·기간 필터가 이 필드에 연동됩니다.
3. **기간 컨트롤 추가**: `컨트롤 추가 → 기간 컨트롤`을 페이지 상단에 배치 → 전체 차트의 날짜 필터가 한 번에 동작. 기본값 "지난 28일" 권장.
4. **비율(%) 집계 주의 (중요)**: `failure_pct`, `block_pct`, `queries_per_user`는 **하루 단위로 이미 계산된 값**입니다. 여러 날을 합산(SUM)하면 틀립니다.
   - 시계열 차트(하루=한 점)에선 그대로 써도 정확.
   - **스코어카드(전체 누계)** 에선 아래 계산된 필드를 만들어 쓰세요:
     - 전체 실패율: `SUM(failures)/SUM(total)` → 형식 `백분율`
     - 전체 차단율: `SUM(blocked)/SUM(inspected)` → 형식 `백분율`
     - 전체 사용자당 쿼리: `SUM(queries)/SUM(active_users)`
5. **데이터 최신성(캐시)**: 각 데이터 소스 → 데이터 최신성 `12시간`으로 설정하면 BQ 스캔비 절감.

---

## 1. KPI 스코어카드 행 (페이지 최상단)

작은 스코어카드 5개를 가로로 배치. 기간 컨트롤과 연동되어 요약 숫자를 보여줌.

| 스코어카드 | 데이터 소스 | 측정항목(Metric) | 집계 | 형식 |
|-----------|-------------|------------------|------|------|
| 총 쿼리 수 | `v_daily_queries` | `queries` | SUM | 정수 |
| 총 에이전트 호출 | `v_daily_agent_calls` | `agent_calls` | SUM | 정수 |
| 활성 사용자(합) | `v_daily_active_users` | `active_users` | SUM* | 정수 |
| 전체 실패율 | `v_daily_failure_rate` | 계산필드 `SUM(failures)/SUM(total)` | — | 백분율 |
| 전체 차단율 | `v_model_armor_block` | 계산필드 `SUM(blocked)/SUM(inspected)` | — | 백분율 |

\* 활성 사용자는 일별 distinct라 기간 합계가 "연인원"입니다. 순수 고유 사용자 수가 필요하면 `v_queries_per_user`의 `user_id`에 **고유 카운트(Count Distinct)** 스코어카드를 별도로 두세요.

---

## 2. 시계열: 일별 쿼리 수

- **차트**: 시계열(선) 또는 세로 막대
- **데이터 소스**: `v_daily_queries`
- **기간 측정기준**: `day`
- **측정항목**: `queries` (SUM)
- **정렬**: `day` 오름차순

---

## 3. 시계열: 유형별 쿼리 (Search vs StreamAssist)

- **차트**: 누적 세로 막대 (또는 다중 선)
- **데이터 소스**: `v_daily_queries_by_method`
- **기간 측정기준**: `day`
- **분류(Breakdown dimension)**: `method`
- **측정항목**: `calls` (SUM)
- **정렬**: `day` 오름차순

---

## 4. 시계열: 에이전트(StreamAssist) 호출 수

- **차트**: 시계열(선)
- **데이터 소스**: `v_daily_agent_calls`
- **기간 측정기준**: `day`
- **측정항목**: `agent_calls` (SUM)

---

## 5. 가로 막대: 사용자당 쿼리 (Top N)

- **차트**: 가로 막대
- **데이터 소스**: `v_queries_per_user`
- **측정기준**: `user_id`
- **측정항목**: `total_queries` (SUM) — 필요시 `agent_calls`, `searches`도 추가해 다중 막대
- **정렬**: `total_queries` 내림차순
- **행 수 제한**: 10~20
- 참고: 이 뷰는 `day`가 없어 기간 컨트롤과 연동 안 됨. 기간별로 보려면 `v_queries_per_user`를 `day`포함 버전으로 바꿔야 함(요청 시 뷰 수정 가능).

---

## 6. 콤보: DAU · 사용자당 평균 쿼리

- **차트**: 콤보(막대+선)
- **데이터 소스**: `v_daily_active_users`
- **기간 측정기준**: `day`
- **측정항목**:
  - 막대(왼쪽 축): `active_users` (SUM)
  - 선(오른쪽 축): `queries_per_user` (**AVG**로 설정 — 비율이므로 SUM 금지)

---

## 7. 실패율 시계열

- **차트**: 콤보(막대+선)
- **데이터 소스**: `v_daily_failure_rate`
- **기간 측정기준**: `day`
- **측정항목**:
  - 막대(왼쪽 축): `total` (SUM)
  - 선(오른쪽 축): `failure_pct` (AVG) — 형식 `백분율`
- **조건부 서식**: `failure_pct` 임계치 초과 시 빨강 강조 가능

---

## 8. 누적 막대: StreamAssist 성공/실패 상태

- **차트**: 누적 세로 막대(100% 누적 추천)
- **데이터 소스**: `v_streamassist_state`
- **기간 측정기준**: `day`
- **분류**: `state` (SUCCEEDED / UNKNOWN / 기타)
- **측정항목**: `n` (SUM)

---

## 9. 콤보: Model Armor 차단율 (프롬프트 vs 응답)

- **차트**: 콤보 또는 누적 막대
- **데이터 소스**: `v_model_armor_block`
- **기간 측정기준**: `day`
- **분류**: `operation` (SANITIZE_USER_PROMPT / SANITIZE_MODEL_RESPONSE)
- **측정항목**:
  - 막대: `inspected` (SUM)
  - 선(보조): `block_pct` (AVG)

---

## 10. 파이/막대: 위협 유형 분포 (RAI + CSAM)

- **차트**: 파이 차트 또는 세로 막대
- **데이터 소스**: `v_model_armor_threats`
- **측정기준**: 없음(기간 전체 합) 또는 파이는 측정기준 없이 측정항목 여러 개
- **측정항목**: `dangerous`, `harassment`, `hate_speech`, `sexually_explicit`, `csam` (각 SUM)
- 참고: Looker Studio 파이는 "측정기준 1 + 측정항목 1" 구조를 선호하므로, 깔끔하게 하려면 뷰를 세로형(threat_type, count)으로 UNPIVOT한 버전이 더 좋음(요청 시 `v_model_armor_threats_long` 생성 가능).

---

## 11. 히트맵/막대: 시간대별 트래픽

- **차트**: 피벗 테이블(히트맵 스타일) 또는 세로 막대
- **데이터 소스**: `v_hourly_heatmap`
- **행 측정기준**: `weekday`
- **열 측정기준**: `hour_of_day`
- **측정항목**: `queries` (SUM)
- **스타일**: 셀 배경색을 값에 따라 그라데이션(피벗 테이블 히트맵) → 사용 피크 시간대 파악
- 참고: `weekday`가 문자열이라 요일 정렬이 알파벳순이 됨. 월~일 순서가 필요하면 `hour_of_day` 기준 막대로 보거나 뷰에 요일 인덱스(1~7) 추가 가능.

---

## 권장 페이지 레이아웃

```
┌─────────────────────────────────────────────┐
│  [기간 컨트롤]                                 │
│  [총쿼리][에이전트][활성유저][실패율][차단율]      │  ← 스코어카드 행
├──────────────────────┬──────────────────────┤
│ 2. 일별 쿼리(선)       │ 3. 유형별 쿼리(누적)    │
├──────────────────────┼──────────────────────┤
│ 4. 에이전트 호출       │ 6. DAU·사용자당 평균     │
├──────────────────────┼──────────────────────┤
│ 7. 실패율             │ 8. 성공/실패 상태        │
├──────────────────────┼──────────────────────┤
│ 9. MA 차단율          │ 10. 위협 유형           │
├──────────────────────┴──────────────────────┤
│ 5. 사용자당 쿼리 Top N (가로 막대, 넓게)         │
├─────────────────────────────────────────────┤
│ 11. 시간대 히트맵 (넓게)                        │
└─────────────────────────────────────────────┘
```
```
```
