# Looker Studio 대시보드 설정 가이드
### Gemini Enterprise + Model Armor 운영·보안 대시보드

데이터 소스: BigQuery → `YOUR_PROJECT_ID` → `gemini_ent_dashboard` → 각 뷰(`v_*`)

> **용어 대응(한글 ↔ 영문 UI)** — Looker Studio를 영문으로 쓰면 화면 라벨이 아래 영문명입니다. 이 가이드의 한글 용어는 이 표로 대조하세요.
>
> | 한글 | English (UI) | 한글 | English (UI) |
> |------|-------------|------|-------------|
> | 측정기준 | **Dimension** | 측정항목 | **Metric** |
> | 기간 측정기준 | Date range dimension | 레코드 수 | Record Count |
> | 집계(합계/평균) | Aggregation (Sum/Average) | 계산필드 | Calculated field |
> | 데이터 소스 | Data source | 차트 | Chart |
> | 표(Table) | Table | 스코어카드 | Scorecard |
> | 시계열 | Time series | 막대(그래프) | Bar chart |
> | 콤보 차트 | Combo chart | 파이 | Pie chart |
> | 트리맵 | Treemap | 피벗 테이블 | Pivot table |
> | 컨트롤 | Control | 기간 컨트롤 | Date range control |
> | 드롭다운 목록 | Drop-down list | 고급 필터 | Advanced filter |
> | 필터 | Filter | 정렬 | Sort |
> | 크로스필터 / 차트 상호작용 | Cross-filtering / Chart interactions | 필터 적용 | Apply filter |
> | 설정 탭 | Setup (tab) | 스타일 탭 | Style (tab) |
> | 검색 표시 | Show search | 포함(필터 조건) | Contains |
> | 리포트/보고서 | Report | 페이지 | Page |

---

## 섹션 0. 리포트 생성 + 데이터 연결 (최초 1회)

> **왜 수동인가:** Looker Studio는 "차트가 배치된 리포트"를 코드로 맨바닥에서 만드는 API가 없습니다. 완성형 대시보드를 자동 배포하려면 **템플릿 리포트를 한 번 손으로 만든 뒤**, Linking API로 복제하는 방식뿐입니다(아래 0-C). 그러니 이 섹션은 딱 한 번만 하면 됩니다.

### 0-A. 빈 리포트 만들고 데이터 소스 추가
1. [lookerstudio.google.com](https://lookerstudio.google.com) → **빈 보고서 만들기**
2. **데이터 추가 → BigQuery → `YOUR_PROJECT_ID` → `gemini_ent_dashboard`** 선택
3. 아래 뷰들을 **각각 데이터 소스로 추가**합니다(리포트에 추가 → 계속 추가):
   `v_daily_queries`, `v_daily_queries_by_method`, `v_daily_agent_calls`, `v_queries_per_user`, `v_daily_active_users`, `v_daily_failure_rate`, `v_streamassist_state`, `v_model_armor_block`, `v_model_armor_threats`, `v_model_armor_threats_long`, `v_hourly_heatmap`, `v_agent_usage_daily`, `v_response_latency_daily`, `v_grounding_top_sources`, `v_grounding_coverage_daily`, `v_user_activity_detail`, `v_model_armor_by_client`, `v_user_agent_trace`, `v_model_armor_verdict_daily`, `v_user_questions`
   - **콘텐츠 인텔리전스(A-8) 뷰** — 콘텐츠 분류(예약 쿼리)를 켠 프로젝트에만 존재: `v_topic_distribution`, `v_intent_distribution`, `v_sentiment_daily` (원본 결과 테이블은 `t_content_topics` — timestamp/day/topic/intent/sentiment).
4. 아래 **섹션 A~11** 가이드대로 차트를 배치합니다.

### 0-B. (권장) 데이터 자격증명 검토
데이터 소스는 기본적으로 **소유자(Owner's) 자격증명**입니다 → 공유받은 사람이 BigQuery 권한 없이도 데이터를 봅니다. 로그에 사용자 이메일·질문 내용이 있으니, 광범위 공유 시엔 **Resource → Manage added data sources → 각 소스 Edit → Viewer's credentials**로 바꾸거나 신뢰 대상에게만 공유하세요.

### 0-C. 자동 재배포를 위한 템플릿 등록 (선택, 강력 권장)
이 리포트를 한 번 완성해두면, 다른 프로젝트에는 **완성형 대시보드를 URL 하나로 복제**할 수 있습니다.
복제 URL은 **`ds.*` 와일드카드로 "프로젝트만" 갈아끼우고** 데이터셋·뷰(테이블)·차트는 템플릿 그대로 유지하므로, **별칭을 뷰 이름과 맞출 필요가 없습니다.** 조건은 하나뿐:
- 모든 데이터 소스가 **BigQuery + `gemini_ent_dashboard` 데이터셋의 뷰**일 것 (다른 데이터셋/커넥터를 섞지 말 것 — 와일드카드가 전부에 적용됨)

절차:
1. 리포트 URL에서 **report id**를 복사합니다 — `.../reporting/`**`<REPORT_ID>`**`/page/...` 의 가운데 부분.
2. 그 값을 넣어 다시 배포하면 완성형 복제 URL이 출력됩니다:
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
`v_model_armor_block`(차단 건수 시계열) + `v_model_armor_threats_long`(위협유형 파이). 아래 9·10·11 항목 참고.

### A-2. ⚡ 응답 지연시간 p50/p95
- **차트(Chart)**: 시계열(Time series, 다중 선)
- **데이터 소스(Data source)**: `v_response_latency_daily`
- **기간 측정기준(Date range dimension) → X축(X-axis)**: `day`
- **분류(선택)**: `agent_id`
- **측정항목(Metric)**: `p50_sec`(AVG), `p95_sec`(AVG) — 형식 숫자(초)
- **스코어카드**: `p95_sec` 최근값을 SLO 타일로 (임계 초과 시 빨강)
- 📖 **수치 읽기**: `p50_sec`=응답시간 **중앙값**(요청 절반은 이보다 빠름), `p95_sec`=**95백분위**(느린 5%의 경계 = 체감 최악 지연). **낮을수록 좋음.** p95가 p50보다 크게 벌어지면 일부 요청만 유독 느린 것 → 꼬리 지연 조사.

### A-3. 📚 그라운딩 신뢰도 (할루시네이션 리스크)
- **차트(Chart)**: 콤보(Combo chart, 막대+선)
- **데이터 소스(Data source)**: `v_grounding_coverage_daily`
- **기간 측정기준(Date range dimension) → X축(X-axis)**: `day`
- **측정항목(Metric)**: 막대=`answers`(SUM), 선(오른축)=`grounded_pct`(AVG, 백분율)
- **스코어카드**: `avg_sources_per_answer`(AVG), 전체 근거율 계산필드 `SUM(grounded_answers)/SUM(answers)`
- 📖 **수치 읽기**: `answers`=그날 어시스턴트 답변 수, `grounded_pct`=**인용 출처가 1개+ 달린 답변 비율(%)**, `avg_sources_per_answer`=답변당 평균 출처 수. **grounded_pct 높을수록 좋음**(출처 근거 = 할루시네이션 리스크↓). 0%에 가까우면 출처 없이 답한 것 → KB 연결/그라운딩 점검.

### A-4. 🔗 인용 출처 Top (콘텐츠 활용도)
- **차트(Chart)**: 가로 막대(Bar chart) 또는 트리맵(Treemap)
- **데이터 소스(Data source)**: `v_grounding_top_sources`
- **측정기준(Dimension) → 축(axis)**: `source`
- **측정항목(Metric)**: `citations`(SUM)
- **정렬**: `citations` 내림차순, 행 수 15
- 참고: 기간필터 필요하면 뷰에 `day` 추가 버전 요청
- 📖 **수치 읽기**: `citations`=해당 출처(도메인/문서)가 답변 근거로 **인용된 횟수**. 값이 큰 출처 = 답변이 주로 의존하는 지식원. 특정 문서에 편중되면 KB 다양성/최신성 점검 신호.

### A-5. 🤖 개별 에이전트별 사용량
- **차트(Chart)**: 누적 막대(Stacked bar) 또는 가로 막대(Bar chart)
- **데이터 소스(Data source)**: `v_agent_usage_daily`
- **기간 측정기준(Date range dimension) → X축(X-axis)**: `day`
- **분류(Breakdown dimension)**: `agent_id` (core_assistant + 커스텀 에이전트)
- **측정항목(Metric)**: `user_turns`(SUM)
- 📖 **수치 읽기**: `user_turns`=각 에이전트(`agent_id`)가 처리한 **사용자 발화(턴) 수**. 어느 에이전트가 실제로 많이 쓰이는지 = 활용도. 특정 에이전트만 쏠리거나 0에 가까운 에이전트 = 방치/홍보 필요 신호.

### A-6. 👤 사용자별 상세 / 드릴다운 (사용자별 검색)
- **차트(Chart)**: 표(Table) — 상호작용 필터용
- **데이터 소스(Data source)**: `v_user_activity_detail` (쿼리 1건 = 1행)
- **측정기준(Dimension)**: `user_id`, `method`, `day` (표는 X축 없음 — 열로 나열)
- **측정항목(Metric)**: 레코드 수(Record Count), `source_count`(AVG)
- 📖 **수치 읽기**: 한 행 = 쿼리 1건. `method`=Search/StreamAssist, `state`=답변 상태(SUCCEEDED 등), `source_count`=그 답변에 붙은 출처 수(0이면 근거 없음). 레코드 수 = 그 사용자의 쿼리 건수.
- **필터 컨트롤 추가**: `user_id` 드롭다운 컨트롤 → **특정 사용자만 필터링** 가능 (= 사용자별 검색)
- 활용: 특정 사용자 선택 시 다른 모든 차트가 그 사용자로 필터되게 하려면 `user_id` 컨트롤을 페이지 상단에 배치하고 데이터 소스를 이 뷰로 통일
- ⚠️ 주의: 사용자별 Model Armor 차단은 **불가** (MA 로그에 사용자ID 없음). 사용자별로 얻을 수 있는 건 쿼리/에이전트/그라운딩까지.

### A-7. 🏷️ Model Armor 업무/비업무 분류
- **차트(Chart)**: 누적 막대(Stacked bar) 또는 표(Table)
- **데이터 소스(Data source)**: `v_model_armor_by_client`
- **기간 측정기준(Date range dimension) → X축(X-axis)**: `day`
- **분류(Breakdown dimension)**: `client_name` (GEMINI_ENTERPRISE_BUSINESS vs NON_BUSINESS)
- **측정항목(Metric)**: `inspected`(SUM), `block_pct`(AVG)
- 📖 **수치 읽기**: `client_name`=업무(GEMINI_ENTERPRISE_BUSINESS)/비업무(NON_BUSINESS) 구분, `inspected`=MA **검사 횟수**(쿼리 수 아님 — #9 주의 참고). 여기선 **업무 vs 비업무 트래픽 비중**을 보는 게 핵심. `block_pct`는 희석되니 참고만.
- 인사이트: 비업무 트래픽 비중을 파악 → 오·남용 모니터링

### A-8. 🧠 콘텐츠 인텔리전스 (Gemini 분류 — 내장에 절대 없음)
BigQuery+Gemini로 사용자 질문을 분류한 결과. 원문은 저장 안 하고 파생 라벨만 사용(프라이버시).
- **토픽 분포**: 차트=파이(Pie)/트리맵(Treemap), 소스=`v_topic_distribution`, 측정기준(Dimension)=`topic`, 측정항목(Metric)=`n`(SUM)
- **의도 분포**: 차트=막대(Bar chart), 소스=`v_intent_distribution`, 측정기준(Dimension) → X축=`intent`(질문/요청/불만/잡담), 측정항목(Metric)=`n`(SUM)
- **일별 감성**: 차트=콤보(Combo chart), 소스=`v_sentiment_daily`, 기간 측정기준 → X축=`day`, 막대=`negative`/`neutral`/`positive`, 선=`negative_pct`(AVG) → **불만·부정 급증 조기경보**
- 📖 **수치 읽기**: `n`=해당 토픽/의도의 질문 **건수**. `negative_pct`=그날 부정 감성 질문 비율(%). **부정 비율이 갑자기 오르면** 서비스 불만/장애 신호 → 해당일 질문 원문(A-9) 확인. (Gemini가 MA 원문을 분류한 파생값, 원문 미저장)

### A-9. 🔎 질문+응답 검색 (누가 무엇을 묻고 어떤 답을 받았나)
사용자 **질문 원문 + 어시스턴트 응답**을 한 행에 셋트로 조회·검색. 소스는 `gemini_enterprise_user_activity` 로그 하나(질문·응답이 같은 행에 있어 조인 불필요), 사용자ID는 `userIamPrincipal`에서 직접.
- **차트(Chart)**: 표(Table)
- **데이터 소스(Data source)**: `v_user_questions` (질문 1건 = 1행, `answer_text` 포함)
- **측정기준(Dimension)**: `question_text`, `answer_text`, `user_id`, `method`(Search/StreamAssist), `day` (원하면 `timestamp`)
- **측정항목(Metric)**: 없음(레코드 목록용) — 필요 시 레코드 수만
- **정렬**: `timestamp`(또는 `day`) 내림차순 → 최신 질문 위로
- 💡 `answer_text`는 **StreamAssist(어시스턴트)** 응답만 채워집니다. Search(키워드 검색)는 LLM 답변이 없어 null. 근거(grounding) 있는 답변은 세그먼트를 순서대로 이어붙여 조립합니다. (일부 빈/중단 턴은 답변 null)
- **검색하는 법 (3가지)**:
  1. **표 검색창**: 차트 스타일 탭 → **"검색 표시(Show search)"** 켜기 → 뷰어가 표 우측 상단 박스에 키워드 입력 시 `question_text`에서 즉시 필터.
  2. **고급 필터 컨트롤**: `컨트롤 추가 → 고급 필터` → 필드 `question_text`, 조건 **"포함(Contains)"** → 특정 단어가 든 질문만 조회.
  3. **user_id / 기간 컨트롤 조합**: A-6과 같은 `user_id` 드롭다운 + 기간 컨트롤로 "특정 사용자가 이번 주에 한 질문"까지 좁힘.
- ⚠️ **전제조건 — 민감 로깅 활성화 필수**: 엔진의 `observabilityConfig.sensitiveLoggingEnabled=true`여야 원문·사용자ID가 평문으로 기록됨. 꺼져 있으면 둘 다 `<elided>`(8자)로 마스킹돼 이 표가 비어 보임. **소급 안 됨** — 켠 시점 이후 로그만 원문. (설정: discoveryengine API `engines/{APP}` PATCH `observabilityConfig.sensitiveLoggingEnabled`)
- ⚠️ **프라이버시 주의**: 이 표는 **질문 원문 + 사용자 신원을 그대로 노출**합니다(A-8 분류 지표와 달리). 보고서 **공유 범위를 관리자/제한된 뷰어로 한정**하고 데이터셋 IAM을 조이세요. 필요 시 별도 페이지로 분리해 접근을 통제.

---

## 섹션 A 권장 페이지 레이아웃 (Page 1 — 대시보드 첫 화면)

```
┌───────────────────────────────────────────────────────────┐
│ [기간 컨트롤]                                [user_id 컨트롤] │
│ [p95 지연(SLO)] [전체 근거율] [MA 차단수] [부정감성 %]        │ ← 경보 스코어카드
├───────────────────────────────┬───────────────────────────┤
│ A-1 MA 차단수 시계열            │ A-1 위협유형 분포(파이)      │
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

> **A-9 질문 원문 검색 표**는 원문 노출 위험 때문에 위 대시보드 첫 화면에 넣지 말고 **별도 페이지(예: "질문 로그")로 분리**해 접근을 통제하는 걸 권장합니다.

---

## 🧩 템플릿 필수 체크리스트 (자동 복제가 되려면 반드시)

복제 URL은 `ds.*` 와일드카드로 **모든 데이터 소스의 프로젝트만** 대상 프로젝트로 바꾸고, 데이터셋·뷰(테이블)·차트는 템플릿 그대로 유지합니다. 그래서 별칭 맞추기는 불필요하고, 대신 아래를 지키세요.

1. **모든 데이터 소스 = BigQuery + `gemini_ent_dashboard` 뷰.** 다른 데이터셋·커넥터를 섞지 마세요 — `ds.*` 가 전부에 적용되므로, 섞이면 엉뚱한 소스까지 프로젝트가 바뀝니다.
2. **페이지마다 기간 컨트롤** 1개씩(자동 복제 후에도 그대로 동작).
3. **크로스필터 켜기**: `파일 → 보고서 설정 → 차트 상호작용 → 필터 적용` 또는 각 차트 `상호작용 → 필터 적용`. 표/컨트롤 클릭이 페이지 전체에 걸리게.
4. **스코어카드 비율은 계산필드**(위 섹션 0의 4번) — 복제해도 계산식이 유지됨.
5. **데이터 최신성 12시간**(각 소스) — 스캔비 절감.
6. 완성 후 **report id 복사** → `-var="looker_studio_template_report_id=<REPORT_ID>"`.

> **A-8(콘텐츠 인텔리전스) 주의:** `v_topic_distribution`·`v_intent_distribution`·`v_sentiment_daily`는 **콘텐츠 분류 옵션(`enable_content_classification=true`)을 켠 프로젝트에만** 존재합니다. `ds.*` 와일드카드는 이들도 같은 데이터셋이면 함께 프로젝트만 바꿔주므로 별도 처리는 필요 없지만, **대상 프로젝트에도 이 3개 뷰가 존재**해야(=분류 활성화) 데이터가 뜹니다. 대상이 분류를 안 켰다면 이 3개 차트는 빈 채로 나오니, 그 경우 A-8을 별도 페이지로 분리하는 것을 권장합니다.

---

## 🧮 계산필드 모음 (스코어카드용)

비율 지표는 **일 단위로 이미 계산된 값**(`failure_pct` 등)이라 기간 합산이 틀립니다. 스코어카드(전체 누계)에는 아래 **계산필드**를 만들어 쓰세요.
만드는 곳: 해당 **데이터 소스 편집 → 필드 추가(ADD A FIELD)**, 또는 차트에서 측정항목 옆 **+ 필드 만들기**.

| 이름 | 데이터 소스 | 수식 | 형식 |
|---|---|---|---|
| 전체 실패율 | `v_daily_failure_rate` | `SUM(failures)/SUM(total)` | 백분율 |
| 총 차단 건수 ⚠️(비율 아님) | `v_model_armor_block` | `blocked` (SUM, 계산필드 불필요) | 정수 |
| 전체 근거율 | `v_grounding_coverage_daily` | `SUM(grounded_answers)/SUM(answers)` | 백분율 |
| 사용자당 쿼리(전체) | `v_daily_active_users` | `SUM(queries)/SUM(active_users)` | 숫자 |
| 프롬프트 인젝션율 | `v_model_armor_verdict_daily` | `SUM(injection_attempts)/SUM(checks)` | 백분율 |
| 부정감성 비율 | `v_sentiment_daily` (분류 옵션 시) | `SUM(negative)/(SUM(negative)+SUM(neutral)+SUM(positive))` | 백분율 |

**⚠️ p95 지연 스코어카드**: 백분위수(p95)는 **여러 날을 평균/합산하면 통계적으로 틀립니다.** 두 방법 중 택:
- `MAX(p95_sec)` → "최악일 p95"(보수적 SLO 지표, 정확). **권장.**
- 또는 기간 컨트롤을 **최근 1일**로 좁혀 `AVG(p95_sec)` 로 당일 값만 표시.

> 팁: 위 계산필드는 **집계식(SUM(...)/SUM(...))** 이라 스코어카드에서 집계를 다시 걸지 마세요(이미 집계됨). 조건부 서식(임계 초과 빨강)은 스코어카드 스타일 탭에서.

### 클릭 단위 예시 — "전체 실패율" 스코어카드
다른 비율 스코어카드도 데이터 소스·수식만 위 표로 바꿔 동일하게 만듭니다.

1. **삽입 → 스코어카드(Scorecard)** → 캔버스에 배치.
2. 오른쪽 **설정(Setup) → 데이터 소스**를 `v_daily_failure_rate` 로 선택. (목록에 없으면 `데이터 추가`로 먼저 연결)
3. **측정항목(Metric)** 의 기본 필드를 클릭 → 팝업 하단 **필드 만들기(Create field)** 클릭.
   - 이름: `전체 실패율`
   - 수식: `SUM(failures)/SUM(total)`
   - **적용(Apply)**.
4. 방금 만든 `전체 실패율`을 측정항목으로 지정. **집계는 Auto 그대로** (이미 SUM 집계식이므로 다시 SUM/AVG 걸지 말 것).
5. **형식**: 측정항목 위 `123` 아이콘(또는 데이터 소스에서 필드 유형) → **백분율(Percent)**, 소수 1자리.
6. **기간 측정기준(Date range dimension)** 이 `day`인지 확인 → 상단 기간 컨트롤에 반응함.

> **MA 차단은 스코어카드도 건수로**: `전체 차단율`(비율)은 분모가 검사 청크라 0.000%로 희석됩니다. 대신 데이터 소스 `v_model_armor_block`, 측정항목 `blocked`(SUM)로 **"총 차단 건수"** 타일을 만드세요(계산필드 불필요).
7. (선택) **스타일 탭 → 조건부 서식**: `전체 실패율` > `0.05`(5%) 이면 글자 빨강 → SLO 경보.
8. 라벨: 스타일 탭에서 이름을 "⚠️ 전체 실패율"로. 스코어카드는 필터 소스로 안 쓰므로 "필터 적용"은 생략.

> 같은 절차로 **전체 실패율**(`v_daily_failure_rate`, `SUM(failures)/SUM(total)`), **전체 근거율**(`v_grounding_coverage_daily`, `SUM(grounded_answers)/SUM(answers)`), **인젝션율**(`v_model_armor_verdict_daily`) 스코어카드를 찍어내면 됩니다.

---

## 🔗 크로스필터 & 컨트롤 설정

### 기간 컨트롤 (가장 넓게 동작)
1. `컨트롤 추가 → 기간 컨트롤` → 페이지 상단 배치. 기본값 "지난 28일".
2. 각 데이터 소스에서 `day` 필드 유형이 **날짜**인지 확인(아니면 시계열·기간필터 연동 안 됨).
3. → `day`를 가진 **모든 차트**가 한 번에 필터됩니다.

### 크로스필터 (차트 클릭 → 다른 차트 필터)
1. 필터 소스로 쓸 차트(표·막대 등)를 선택 → 오른쪽 **설정(Setup)** 하단 **차트 상호작용 → "필터 적용"** 체크. (전역 토글 없음 — **차트마다** 켬)
2. 이제 그 차트에서 값(막대/행)을 클릭하면 **같은 페이지의 다른 차트 중 그 측정기준을 가진 것**들이 필터됩니다.
3. **범위 주의:** 크로스필터는 **필드 이름이 같은 데이터 소스**에만 걸립니다. 뷰마다 데이터 소스가 달라서, 예컨대 `user_id`는 `user_id`가 있는 뷰(`v_user_activity_detail`, `v_queries_per_user`)에만 적용됩니다. `day`처럼 공통 필드가 가장 넓게 먹습니다.

### user_id 드릴다운 컨트롤 (사용자별 검색)
1. `컨트롤 추가 → 드롭다운 목록` → 데이터 소스 `v_user_activity_detail` → 컨트롤 필드 `user_id`.
2. 이 컨트롤은 `user_id`를 가진 차트만 필터합니다. 사용자별 상세 표(A-6)와 함께 배치하면 "특정 사용자 선택 → 그 사용자 활동만" 필터가 됩니다.
3. 사용자별로 보안(Model Armor)까지 엮는 건 **불가**(MA 로그에 user_id 없음).

---

## 🧩 까다로운 차트 클릭 단위 (콤보·히트맵·파이)

축·집계·정렬에서 실수가 잦은 세 유형만 클릭 단위로. 나머지 단순 시계열·막대는 각 섹션 스펙대로.

### 콤보 차트 — 예시: 7 "실패율" (막대=쿼리 수, 선=실패율%)
데이터 소스 `v_daily_failure_rate` (필드: `day`, `failures`, `total`, `failure_pct`).
※MA 차단율은 분모(`inspected`=검사 청크)가 부풀려져 콤보에 부적합 — **9번은 `blocked` 막대**로 보세요.

1. **삽입 → 콤보 차트(Combo chart)** → 배치.
2. Setup → **데이터 소스(Data source)** = `v_daily_failure_rate`, **기간 측정기준(Date range dimension) → X축** = `day`.
3. **측정기준(Dimension)** = `day`. (분류 측정기준은 비워둠 — 아래 정확도 노트 참고)
4. **측정항목 2개**:
   - 측정항목 1 = `total`, 집계 **SUM** (막대: 전체 쿼리 수)
   - 측정항목 2 = 계산필드 **`전체 실패율`**(`SUM(failures)/SUM(total)`), 형식 백분율
     → 선 지표는 이 **계산필드**를 쓰세요. `failure_pct`를 AVG로 쓰면 일별 값을 단순평균해 가중치가 틀립니다.
5. **스타일(Style) 탭 → 시리즈(Series)**:
   - 시리즈 #1(`total`) = **막대(Bars)**, 축 **왼쪽**
   - 시리즈 #2(`전체 실패율`) = **선(Line)**, 축 **오른쪽**
6. 오른쪽 축 범위를 0~1(또는 0~자동)로, 왼쪽 축은 건수. 데이터 라벨은 선만 켜면 깔끔.

> **MA 프롬프트 vs 응답 차단을 나눠 보고 싶으면**: 측정기준=`day`, **분류 측정기준=`operation`**, 측정항목=**`blocked`(SUM)** 로 그룹/누적 막대(9번). `inspected`·`block_pct`는 위 이유로 지양.

**같은 콤보 패턴 재사용** (측정기준=`day`, 막대=건수 SUM, 선=비율 계산필드/AVG, 오른쪽 축):
| 차트 | 소스 | 막대(왼쪽) | 선(오른쪽) |
|---|---|---|---|
| A-3 그라운딩 신뢰도 | `v_grounding_coverage_daily` | `answers`(SUM) | `전체 근거율` 계산필드 |
| 7 실패율 | `v_daily_failure_rate` | `total`(SUM) | `전체 실패율` 계산필드 |
| 6 DAU·사용자당 | `v_daily_active_users` | `active_users`(SUM) | `queries_per_user`(**AVG**) |

### 히트맵 — 11 "시간대별 트래픽" (피벗 테이블 + 그라데이션)
데이터 소스 `v_hourly_heatmap` (필드: `weekday`, `hour_of_day`, `queries`).

1. **삽입 → 피벗 테이블(Pivot table)** → 배치.
2. Setup → **데이터 소스(Data source)** = `v_hourly_heatmap`.
3. **행 측정기준(Row dimension)** = `weekday`.
4. **열 측정기준(Column dimension)** = `hour_of_day`.
5. **측정항목(Metric)** = `queries`, 집계 **SUM**.
6. **셀 색상(히트맵)**: 측정항목의 색상 유형을 **"히트맵"**(값에 따른 그라데이션)으로 설정. (Setup의 측정항목 옆 색상 옵션, 또는 스타일 탭 셀 배경색)
7. **요일 정렬 문제**: `weekday`가 문자열이라 알파벳순(Friday, Monday…)이 됩니다. 월~일 순서로 고치려면 데이터 소스에 계산필드를 만들어 정렬:
   ```
   CASE weekday
     WHEN "Monday" THEN 1 WHEN "Tuesday" THEN 2 WHEN "Wednesday" THEN 3
     WHEN "Thursday" THEN 4 WHEN "Friday" THEN 5 WHEN "Saturday" THEN 6
     WHEN "Sunday" THEN 7 END
   ```
   이름 `weekday_order` → 피벗 **정렬(Sort)** 에서 행 정렬 기준을 `weekday_order` 오름차순으로.
   (정렬 기준으로 못 고르면, 표시용으로 `CONCAT(weekday_order," ",weekday)` 필드를 만들어 행 측정기준으로 쓰면 "1 Monday"…로 정렬됨.)

### 파이 — 10 "위협 유형 분포"
`v_model_armor_threats`는 위협유형이 **열(컬럼)** 이라 파이에 부적합합니다. **UNPIVOT된 `v_model_armor_threats_long`(필드: `day`, `threat_type`, `threat_count`)** 를 쓰세요:
1. **삽입 → 원형 차트(Pie)** → 소스 `v_model_armor_threats_long`.
2. **측정기준(Dimension)** = `threat_type`, **측정항목(Metric)** = `threat_count`(SUM).
3. 정렬 `threat_count` 내림차순. 기간 컨트롤 연동 원하면 `day`가 있으니 그대로 반응.

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
     - 전체 근거율: `SUM(grounded_answers)/SUM(answers)` → 형식 `백분율` (※MA 차단은 비율 대신 `SUM(blocked)` 건수로)
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
| 총 차단 건수 | `v_model_armor_block` | `blocked` | SUM | 정수 |

\* 활성 사용자는 일별 distinct라 기간 합계가 "연인원"입니다. 순수 고유 사용자 수가 필요하면 `v_queries_per_user`의 `user_id`에 **고유 카운트(Count Distinct)** 스코어카드를 별도로 두세요.

📖 **KPI 수치 읽기**: **총 쿼리 수**=기간 내 전체 쿼리, **총 에이전트 호출**=StreamAssist 수(대화형 사용량), **활성 사용자**=연인원(위 * 참고), **전체 실패율**=ERROR+ 로그 비율(낮을수록 좋음), **총 차단 건수**=MA가 차단한 건수(비율 아님 — #9 참고).

---

## 2. 시계열: 일별 쿼리 수

- **차트(Chart)**: 시계열(Time series, 선) 또는 세로 막대(Bar chart)
- **데이터 소스(Data source)**: `v_daily_queries`
- **기간 측정기준(Date range dimension) → X축(X-axis)**: `day`
- **측정항목(Metric)**: `queries` (SUM)
- **정렬**: `day` 오름차순
- 📖 **수치 읽기**: `queries`=하루 총 쿼리 수(**Search + StreamAssist 합**). 전체 사용량 추세 — 급증/급감일을 다른 차트와 대조해 원인 파악.

---

## 3. 시계열: 유형별 쿼리 (Search vs StreamAssist)

- **차트(Chart)**: 누적 세로 막대(Stacked bar, 또는 다중 선)
- **데이터 소스(Data source)**: `v_daily_queries_by_method`
- **기간 측정기준(Date range dimension) → X축(X-axis)**: `day`
- **분류(Breakdown dimension)**: `method`
- **측정항목(Metric)**: `calls` (SUM)
- **정렬**: `day` 오름차순
- 📖 **수치 읽기**: `calls`=유형별 쿼리 수. **Search**=키워드 검색, **StreamAssist**=어시스턴트 대화. 둘의 비중으로 "검색 위주 vs 대화 위주" 사용 패턴을 봄.

---

## 4. 시계열: 에이전트(StreamAssist) 호출 수

- **차트(Chart)**: 시계열(Time series, 선)
- **데이터 소스(Data source)**: `v_daily_agent_calls`
- **기간 측정기준(Date range dimension) → X축(X-axis)**: `day`
- **측정항목(Metric)**: `agent_calls` (SUM)
- 📖 **수치 읽기**: `agent_calls`=**StreamAssist(어시스턴트) 호출 수** = 대화형 사용량. 섹션 2의 전체 쿼리 대비 이 비중이 대화형 채택도를 보여줌.

---

## 5. 가로 막대: 사용자당 쿼리 (Top N)

- **차트(Chart)**: 가로 막대(Bar chart)
- **데이터 소스(Data source)**: `v_queries_per_user`
- **측정기준(Dimension) → 축(axis)**: `user_id`
- **측정항목(Metric)**: `total_queries` (SUM) — 필요시 `agent_calls`, `searches`도 추가해 다중 막대
- **정렬**: `total_queries` 내림차순
- **행 수 제한**: 10~20
- 참고: 이 뷰는 `day`가 없어 기간 컨트롤과 연동 안 됨. 기간별로 보려면 `v_queries_per_user`를 `day`포함 버전으로 바꿔야 함(요청 시 뷰 수정 가능).
- 📖 **수치 읽기**: `total_queries`=사용자별 누적 쿼리 수(`agent_calls`+`searches`). 상위 사용자 = 헤비 유저(파워 유저 or 자동화/오남용 의심). 극단적으로 튀는 사용자는 별도 확인.

---

## 6. 콤보: DAU · 사용자당 평균 쿼리

- **차트(Chart)**: 콤보(Combo chart, 막대+선)
- **데이터 소스(Data source)**: `v_daily_active_users`
- **기간 측정기준(Date range dimension) → X축(X-axis)**: `day`
- **측정항목(Metric)**:
  - 막대(왼쪽 축): `active_users` (SUM)
  - 선(오른쪽 축): `queries_per_user` (**AVG**로 설정 — 비율이므로 SUM 금지)
- 📖 **수치 읽기**: `active_users`=그날 **고유 사용자 수(DAU)**, `queries_per_user`=사용자당 평균 쿼리(=참여도). DAU는 늘고 사용자당 쿼리는 유지/상승이면 건강한 성장. 사용자당 쿼리가 급락하면 이탈/불만 신호.

---

## 7. 실패율 시계열

- **차트(Chart)**: 콤보(Combo chart, 막대+선)
- **데이터 소스(Data source)**: `v_daily_failure_rate`
- **기간 측정기준(Date range dimension) → X축(X-axis)**: `day`
- **측정항목(Metric)**:
  - 막대(왼쪽 축): `total` (SUM)
  - 선(오른쪽 축): `failure_pct` (AVG) — 형식 `백분율`
- **조건부 서식**: `failure_pct` 임계치 초과 시 빨강 강조 가능
- 📖 **수치 읽기**: `total`=전체 로그 수, `failure_pct`=**severity가 ERROR+ 인 비율(%)**. **낮을수록 좋음.** ⚠️ 이건 로그 심각도 기반이라 "실제 답변 실패"와 정확히 일치하진 않음 — 답변 실패는 8번(`state`)이 더 직접적. 급증일만 잡아 원인 로그 확인.

---

## 8. 누적 막대: StreamAssist 성공/실패 상태

- **차트(Chart)**: 누적 세로 막대(Stacked bar, 100% 누적 추천)
- **데이터 소스(Data source)**: `v_streamassist_state`
- **기간 측정기준(Date range dimension) → X축(X-axis)**: `day`
- **분류(Breakdown dimension)**: `state` (SUCCEEDED / UNKNOWN / 기타)
- **측정항목(Metric)**: `n` (SUM)
- 📖 **수치 읽기**: `n`=상태별 답변 수. `SUCCEEDED` 비중이 높아야 정상. `UNKNOWN`/기타가 늘면 답변 생성 문제 → 100% 누적 막대로 비율 변화를 추적.

---

## 9. 막대: Model Armor 차단 건수 (프롬프트 vs 응답)

- **차트(Chart)**: 세로 막대(Bar chart) 또는 시계열(Time series)
- **데이터 소스(Data source)**: `v_model_armor_block`
- **기간 측정기준(Date range dimension) → X축(X-axis)**: `day`
- **분류(Breakdown dimension)**: `operation` (SANITIZE_USER_PROMPT / SANITIZE_MODEL_RESPONSE)
- **측정항목(Metric)**: `blocked` (SUM) ← **차단된 건수** (실질 보안 신호)
- **스코어카드(Scorecard)**: `blocked`(SUM) → "총 차단 건수" 타일
- ⚠️ **`inspected`·`block_pct`는 쓰지 마세요**: `inspected`는 MA **검사 횟수**(프롬프트·응답을 스트리밍/부분 단위로 반복 검사 → 76만 건대, **쿼리 수 아님**)라 축이 200k+로 부풀고, `block_pct`는 그걸 분모로 써서 차단이 1~5건뿐이면 0.000%로 희석됩니다. 보안 관점의 핵심은 **차단이 몇 건인지(`blocked`)**.
- 쿼리 단위 차단율은 **불가**(MA 로그에 쿼리ID/trace 없어 쿼리로 못 묶음).

---

## 10. 파이/막대: 위협 유형 분포 (RAI + CSAM)

- **차트(Chart)**: 파이 차트(Pie chart) 또는 세로 막대(Bar chart)
- **데이터 소스(Data source)**: `v_model_armor_threats`
- **측정기준(Dimension)**: 없음(기간 전체 합, X축 없음) 또는 파이는 측정기준 없이 측정항목 여러 개
- **측정항목(Metric)**: `dangerous`, `harassment`, `hate_speech`, `sexually_explicit`, `csam` (각 SUM)
- 📖 **수치 읽기**: 각 값 = 그 위협 유형으로 **탐지된 건수**(폭력적/괴롭힘/혐오/성적/아동성착취). 어떤 위협이 주로 들어오는지 분포 파악용. 절대량이 작아도 CSAM 등은 1건도 중요 — 건수 자체를 보세요.
- 참고: Looker Studio 파이는 "측정기준 1 + 측정항목 1" 구조를 선호하므로, 깔끔하게 하려면 뷰를 세로형(threat_type, count)으로 UNPIVOT한 버전이 더 좋음(요청 시 `v_model_armor_threats_long` 생성 가능).

---

## 11. 히트맵/막대: 시간대별 트래픽

- **차트(Chart)**: 피벗 테이블(Pivot table, 히트맵 스타일) 또는 세로 막대(Bar chart)
- **데이터 소스(Data source)**: `v_hourly_heatmap`
- **행 측정기준(Row dimension → Y축)**: `weekday`
- **열 측정기준(Column dimension → X축)**: `hour_of_day`
- **측정항목(Metric)**: `queries` (SUM)
- 📖 **수치 읽기**: 셀 값=해당 **요일×시간대의 쿼리 수**. 색이 진한 칸 = 사용 피크. 업무시간 집중 여부·야간 사용 등을 파악 → 용량 계획/공지 타이밍에 활용.
- **스타일**: 셀 배경색을 값에 따라 그라데이션(피벗 테이블 히트맵) → 사용 피크 시간대 파악
- 참고: `weekday`가 문자열이라 요일 정렬이 알파벳순이 됨. 월~일 순서가 필요하면 `hour_of_day` 기준 막대로 보거나 뷰에 요일 인덱스(1~7) 추가 가능.

---

## 권장 페이지 레이아웃

```
┌─────────────────────────────────────────────┐
│  [기간 컨트롤]                                 │
│  [총쿼리][에이전트][활성유저][실패율][차단수]      │  ← 스코어카드 행
├──────────────────────┬──────────────────────┤
│ 2. 일별 쿼리(선)       │ 3. 유형별 쿼리(누적)    │
├──────────────────────┼──────────────────────┤
│ 4. 에이전트 호출       │ 6. DAU·사용자당 평균     │
├──────────────────────┼──────────────────────┤
│ 7. 실패율             │ 8. 성공/실패 상태        │
├──────────────────────┼──────────────────────┤
│ 9. MA 차단수          │ 10. 위협 유형           │
├──────────────────────┴──────────────────────┤
│ 5. 사용자당 쿼리 Top N (가로 막대, 넓게)         │
├─────────────────────────────────────────────┤
│ 11. 시간대 히트맵 (넓게)                        │
└─────────────────────────────────────────────┘
```
```
```
