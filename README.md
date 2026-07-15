# Gemini Enterprise · 운영/보안/콘텐츠 대시보드

Gemini Enterprise + Model Armor의 Cloud Logging 로그를 **Log Analytics(무료 연합 조회) → BigQuery 뷰 → Looker Studio(무료)** 로 시각화하는 대시보드 솔루션입니다. 내장 애널리틱스가 못 보여주는 **보안(Model Armor·프롬프트 인젝션) · 응답 지연(SLO) · 그라운딩 신뢰도 · 콘텐츠 토픽/감성**까지 한 번의 `terraform apply`로 배포합니다.

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://console.cloud.google.com/cloudshell/open?cloudshell_git_repo=https://github.com/sykang169/gemini-enterprise-dashboard&cloudshell_tutorial=tutorial.md&cloudshell_workspace=.)

> 버튼을 누르면 Cloud Shell이 이 저장소를 클론하고 `tutorial.md` 대화형 가이드 패널을 띄웁니다. (누구나 클릭 가능 — 본인 GCP 프로젝트에 배포됩니다)

---

## 🚀 Quickstart (3단계)

```bash
# 1) 클론
git clone https://github.com/sykang169/gemini-enterprise-dashboard.git && cd gemini-enterprise-dashboard

# 2) 배포 (프로젝트 소유자/편집자 권한 + 결제 활성화 필요, ~7분)
./deploy.sh <YOUR_PROJECT_ID>

#    질문·응답 원문까지 수집하려면 (아래 경고 먼저 읽으세요 — 소급 안 됨):
# ./deploy.sh <YOUR_PROJECT_ID> -var="enable_sensitive_logging=true"

# 3) Looker Studio 대시보드 구성 (looker_studio_setup.md 가이드 따라)
#    - 최초 1회: 뷰를 데이터 소스로 연결해 차트 배치 (섹션 0)
#    - 이후 자동: 그 리포트를 템플릿으로 등록하면 URL 하나로 완성형 대시보드 복제
```

`deploy.sh`가 하는 일: 결제/인증 preflight → 필요한 API 활성화 → **원격 state 버킷 생성 + init** → BigQuery 데이터셋 → Log Analytics 링크 → BQ↔Gemini 연결·IAM → (IAM 전파 5분 대기 내장) → Gemini 원격 모델 → 대시보드 뷰 26개(지표 24 + 배관 2) → (옵션) 콘텐츠 분류·예약 쿼리 → **Looker Studio 구성 안내(또는 템플릿 지정 시 완성형 대시보드 복제 URL) 출력**.

> ### 🗄️ Terraform state는 GCS에 있습니다 (다른 PC에서 배포해도 안전)
>
> state는 `gs://<PROJECT_ID>-tfstate`(버전관리 켜짐)에 저장되며 `deploy.sh`가 없으면 만들어줍니다. 로컬 파일이 아니라서 **어느 PC에서 배포하든 같은 state를 읽고 변경분만 반영**합니다.
>
> 이게 중요한 이유: BigQuery job의 `job_id`는 실행할 SQL의 sha256이고 **프로젝트+위치당 영구히 유일**합니다. state가 없는 PC에서 같은 프로젝트에 재배포하면 Terraform이 그 job을 다시 만들려다 `Already Exists: Job ...`로 **apply가 중단**됩니다(자원이 재생성되는 게 아니라 그냥 멈춥니다). 원격 state가 이 문제를 근본적으로 없앱니다.
>
> **버킷 이름은 전역 유일**이라 충돌하면 직접 지정하세요: `STATE_BUCKET=my-unique-tfstate ./deploy.sh <PROJECT_ID>`
>
> **이미 로컬 state로 배포한 적이 있다면**, state를 가진 그 PC에서 **한 번만** 마이그레이션하세요. 안 하면 그 PC만 알던 BigQuery job 정보가 사라져 다음 배포가 위 409에 걸립니다:
>
> ```bash
> terraform -chdir=terraform init -migrate-state \
>   -backend-config="bucket=<PROJECT_ID>-tfstate" \
>   -backend-config="prefix=gemini-ent-dashboard"
> ```
>
> **그 state가 이미 사라졌다면** job을 한 번 수동 import하면 됩니다:
>
> ```bash
> P=<PROJECT_ID>
> JOB=$(bq ls -j --max_results=1000 --format=json $P \
>   | python3 -c 'import sys,json;print(next(j["jobReference"]["jobId"] for j in json.load(sys.stdin) if j["jobReference"]["jobId"].startswith("create_model_gemini_flash")))')
> terraform -chdir=terraform import -var="project_id=$P" \
>   google_bigquery_job.create_model_gemini_flash "projects/$P/jobs/$JOB/location/US"
> ```

> **Looker Studio 자동 생성:** Looker Studio는 차트를 코드로 맨바닥에서 만드는 API가 없어, 완성형 대시보드는 **템플릿 리포트 복제** 방식으로 자동화합니다. `looker_studio_setup.md` 섹션 0을 따라 한 번 템플릿을 만들고 `-var="looker_studio_template_report_id=<REPORT_ID>"`로 배포하면, 이후 어떤 프로젝트든 완성형 대시보드를 한 URL로 복제 생성합니다.

> ### ⚠️ 질문·응답 원문을 보려면 배포 **전에** 결정하세요 (`enable_sensitive_logging`)
>
> Gemini Enterprise는 기본적으로 로그의 민감 필드를 `<elided>`로 마스킹합니다. 이 플래그 없이 배포하면 **질문·응답·사용자ID가 전부 가려진 채 쌓이고**, `v_user_questions`는 비어 보이며 `v_queries_per_user`·`v_daily_active_users`는 사용자 1명으로 붕괴하고 콘텐츠 분류는 분류할 텍스트가 없습니다.
>
> **소급이 안 됩니다.** 나중에 켜도 그 전 로그는 영구히 마스킹 상태입니다.
>
> ```bash
> ./deploy.sh <YOUR_PROJECT_ID> -var="enable_sensitive_logging=true"
> ```
>
> 기본 동작(AUTO)은 **이미 로그를 내보내는 엔진만** 골라 마스킹을 풀어, 새 로그 발생·추가 청구 없이 기존 행만 원문화합니다. 관측성이 꺼진 엔진은 건너뛰고 목록으로 알려줍니다 — 그런 새 앱은 `-var='sensitive_logging_engine_ids=["ENGINE_ID"]'`로 지정하면 관측성까지 켜줍니다.
>
> **켜면 최종 사용자 프롬프트와 신원이 평문으로** Cloud Logging에 기록되고 BigQuery로 복사됩니다. 실제 PII이므로 `gemini_ent_analytics`·`gemini_ent_dashboard` 데이터셋 IAM을 열람 권한자로 제한하세요. 되돌리기는 수동입니다 — 자세한 내용은 `terraform/sensitive_logging.tf` 주석 참고.

---

## 아키텍처

```
[Gemini Enterprise / Model Armor]
        │  Cloud Logging 실시간 자동 수집
        ▼
[_Default 로그 버킷]  ← 로그의 실체는 여기에만. 리텐션이 곧 수명(기본 30일)
        │  Log Analytics — federated VIEW (numBytes=0, 사본 아님)
        ▼
[gemini_ent_analytics._AllLogs]
        │  매시간 증분 MERGE (sql/03) — 뷰가 읽는 로그만, 중복키로 멱등
        ▼
[t_logs_archive]  ← 영구 보관. 일 파티션 + log_name 클러스터
        │
        ├─ v_log_source ── SQL 지표 뷰 24개 ──▶ [Looker Studio (무료)]
        │
        └─ (옵션) 질문 원문
             └─ BigQuery + Gemini(gemini-2.5-flash-lite) 분류
                  └─ 토픽/의도/감성 뷰  ← 매일 03:00 KST 예약 쿼리로 갱신
```

**핵심 두 가지.**

**로그를 BigQuery로 스트리밍하지 않습니다.** `_AllLogs`는 로그 버킷을 보는 연합 뷰라 저장비가 0입니다. 대신 **버킷 리텐션이 곧 대시보드의 기억 한계**라, 그걸 넘기려면 아래 아카이브가 필요합니다.

**뷰는 `_AllLogs`가 아니라 아카이브를 읽습니다.** `_AllLogs`는 날짜로만 파티션돼 `log_name` 프루닝이 안 되므로, 한 번 읽으면 그 기간의 무관한 로그(전체의 73%)까지 통째로 스캔합니다 — 차트 1회 조회에 **7.5GB**. 아카이브는 필요한 로그만 담고 파티션·클러스터가 걸려 있어 같은 조회가 **1.28MB**입니다. 대가는 **최대 1시간 지연**이고, 모든 지표가 일별 집계라 실제로 읽히는 값은 달라지지 않습니다.

> ### 📦 로그 보관 한계와 아카이브 (`enable_log_archive`)
>
> 위 구조의 대가가 하나 있습니다. `_AllLogs`는 로그 버킷을 보는 **뷰**라 자체 저장량이 0바이트입니다(`numBytes=0`으로 확인 가능). 즉 **로그 버킷의 리텐션이 곧 대시보드의 기억 한계**이고, 기본 30일이면 모든 뷰가 30일 롤링 윈도우가 됩니다. 만료된 로그는 **백필이 없어 영구 소실**입니다.
>
> ```bash
> ./deploy.sh <YOUR_PROJECT_ID> \
>   -var="enable_log_archive=true" -var="enable_scheduled_archive=true"
> ```
>
> 뷰가 실제로 읽는 로그만 골라 `t_logs_archive`(파티션 테이블)에 증분 복사합니다. **38일 기준 20.6GB → 11MB** — 저장비는 반올림하면 0입니다. **매시간** 증분 실행하며, 중복키 `(log_name, timestamp, insert_id)` MERGE라 재실행해도 안전합니다.
>
> **뷰는 아카이브만 읽습니다**(`v_log_source`). `_AllLogs`는 날짜로만 파티션돼 `log_name` 프루닝이 불가능해서, 한 번 읽으면 그 기간의 무관한 로그(전체의 73%)까지 `json_payload`를 통째로 스캔합니다. 실측으로 차트 조회가 **7,502MB → 1.28MB (5,861배↓)** 였습니다. 대가는 **최대 1시간 지연**인데, 모든 지표가 일별 집계라 차트가 읽히는 값은 달라지지 않습니다.
>
> **반드시 미리 켜세요.** 아카이브는 버킷에 아직 남아 있는 것만 저장할 수 있어, 리텐션이 지난 뒤 켜면 그 데이터는 돌아오지 않습니다.
>
> **차트는 기본 90일까지만 봅니다**(`dashboard_window_days`). 아카이브는 전부 보관하지만, 상한이 없으면 차트 스캔이 배포 연차만큼 계속 늘어납니다 — 3년 된 설치가 "일별 쿼리" 하나 그리려고 3년치를 훑게 됩니다. 더 오래된 이력은 `v_log_source_all` 뷰로 조회하세요(항상 `timestamp` 필터와 함께). Looker에 날짜 범위 컨트롤이 있으면 그것도 파티션까지 프루닝됩니다 — 이 상한은 컨트롤이 없는 차트를 위한 안전망입니다.

---

## 대시보드 지표 (24개 뷰)

| 그룹 | 내용 | 내장 대비 |
|------|------|-----------|
| **운영** | 일별/유형별 쿼리, DAU, 사용자당 쿼리, 시간대 히트맵 — **앱(engine_id)별 분리 가능** | 유사 |
| **🛡️ 보안** | Model Armor 차단율, 위협유형(폭력/혐오/성/CSAM/**프롬프트 인젝션**), verdict, 업무/비업무 분류 | **없음** |
| **⚡ 지연** | 응답 p50/p95 (trace 기반), 사용자·에이전트별 | **없음** |
| **📚 품질** | 그라운딩 커버리지(할루시네이션 리스크), 인용 출처 Top | **없음** |
| **🧠 콘텐츠** | 질문 토픽 분포, 의도, 감성(부정 급증 경보) — Gemini 분류 | **없음** |
| **🤖 에이전트** | **에이전트별 실제 호출**(`v_agent_usage_daily`) + **페이지 조회**(`v_agent_page_views`) — 둘을 대비하면 "보기만 하고 안 쓰는" 에이전트가 드러남 | **없음** |
| **👤 사용자** | 행 단위 드릴다운(user_id 필터), **질문 원문 검색**(`v_user_questions`) | 제한적 |

---

## 저장소 구조

```
├── README.md                     # 이 문서 (솔루션 개요·배포)
├── deploy.sh                     # 원큐 배포 래퍼
├── tutorial.md                   # Cloud Shell 대화형 가이드
├── AUTOMATION.md                 # 자동화 상세 지도
├── looker_studio_setup.md        # Looker Studio 생성·차트 배치·템플릿 등록 가이드
├── looker_studio_create_url.txt  # 템플릿 복제 URL (생성물, 템플릿 지정 시에만)
├── log_analytics_dashboard_queries.sql  # 원본 KPI 쿼리 모음
├── sql/
│   ├── 01_create_views.sql       # 뷰 23개: 지표 21개 + v_log_source(차트용) + v_log_source_all(ad-hoc)
│   ├── 02_content_classification.sql  # Gemini 콘텐츠 분류 (옵션)
│   └── 03_archive_logs.sql       # 로그 아카이브 증분 MERGE (옵션)
├── notebook/
│   └── gemini_enterprise_dashboard_setup.ipynb  # Python 대안 경로
└── terraform/                    # IaC (apply 한 번으로 전체 구성)
    ├── apis.tf · providers.tf · variables.tf · datasets.tf
    ├── backend.tf                # GCS 원격 state (다른 PC에서 배포해도 안전)
    ├── logging.tf · connection.tf · model_and_views.tf
    ├── sensitive_logging.tf      # 옵션: 원문·사용자ID 마스킹 해제
    ├── archive.tf                # 옵션: 로그 영구 보관 + 매시간 증분
    ├── scheduled_query.tf · outputs.tf
    ├── terraform.tfvars.example
    └── README.md
```

---

## 옵션 & 비용

| 옵션 | 기본 | 설명 |
|------|------|------|
| `enable_sensitive_logging` | `false` | 질문·응답·사용자ID를 평문으로 기록 (**소급 불가** — 배포 전 결정). PII |
| `sensitive_logging_engine_ids` | `[]` | 빈 값 = 이미 로깅 중인 엔진만 마스킹 해제. 지정 시 그 엔진의 관측성까지 활성화 |
| `enable_log_archive` | `false` | 로그를 `t_logs_archive`에 영구 보관 (리텐션 만료 대비, **미리 켜야 의미 있음**) |
| `enable_scheduled_archive` | `false` | 매시간 증분 아카이브. **차트가 아카이브만 읽으므로 이게 곧 대시보드 갱신 주기** |
| `archive_schedule` | `every 1 hours` | 위 스케줄(UTC). `sql/03`의 lookback(3h)보다 길게 늘리지 말 것 |
| `dashboard_window_days` | `90` | 차트가 읽는 기간 상한. 아카이브는 전부 보관 (`0` = 무제한) |
| `enable_content_classification` | `false` | Gemini로 질문 토픽/감성 분류 (행당 Gemini 호출 비용) |
| `enable_scheduled_classification` | `false` | 매일 03:00 KST 자동 재분류 (예약 쿼리) |

- **Log Analytics / 뷰 / Looker Studio**: 사실상 무료 (로그 보관비 + 소량 BQ 스캔)
- **로그 아카이브(옵션)**: 뷰가 읽는 로그만 담아 38일 기준 **11MB** — 저장비는 반올림하면 0. 매시간 MERGE가 실측 **21MB/회**
- **콘텐츠 분류(옵션)**: `gemini-2.5-flash-lite` 사용으로 저비용. 분류한 건수만큼 과금
- **차트 스캔**: 아카이브 전용 + 90일 윈도우로 조회당 **~1.3MB** (아카이브 전에는 7.5GB였음)

---

## 사용법 예시

### 1) 기본 배포 (가장 흔한 경우)
```bash
./deploy.sh my-gcp-project
# 내부적으로: terraform -chdir=terraform init && apply -var project_id=my-gcp-project
```

### 2) 콘텐츠 분류(토픽/감성)까지 켜서 배포
```bash
cd terraform
terraform init
terraform apply \
  -var project_id=my-gcp-project \
  -var enable_content_classification=true
# → 사용자 질문을 Gemini(gemini-2.5-flash-lite)로 분류, v_topic_distribution 등 생성
```

### 3) 매일 자동 재분류(예약 쿼리)까지 켜기
```bash
terraform apply \
  -var project_id=my-gcp-project \
  -var enable_content_classification=true \
  -var enable_scheduled_classification=true
# → 매일 03:00 KST(18:00 UTC) 신규 질문 자동 분류
# ⚠️ 이미 수동 생성한 예약 쿼리가 있으면 중복 방지 위해 scheduled_query.tf 주석 참고
```

### 4) 데이터셋/리전/스케줄 커스터마이즈
```bash
terraform apply \
  -var project_id=my-gcp-project \
  -var bq_location=asia-northeast3 \
  -var dashboard_dataset_id=ge_dashboard \
  -var scheduled_query_schedule="every day 21:00"   # 21:00 UTC = 06:00 KST
```
또는 `terraform.tfvars` 파일로:
```hcl
project_id                    = "my-gcp-project"
enable_content_classification = true
gemini_endpoint               = "gemini-2.5-flash"   # 정확도 우선 시
```

### 5) 뷰 SQL만 수동 실행 (Terraform 없이)
```bash
# YOUR_PROJECT_ID 를 실제 프로젝트로 치환 후 실행
sed 's/YOUR_PROJECT_ID/my-gcp-project/g' sql/01_create_views.sql | bq query --use_legacy_sql=false
```

### 6) 배포 후 데이터 확인 (샘플 쿼리)
```bash
# 일별 쿼리 수
bq query --use_legacy_sql=false \
  'SELECT * FROM `my-gcp-project.gemini_ent_dashboard.v_daily_queries` ORDER BY day'

# Model Armor 위협 유형 분포
bq query --use_legacy_sql=false \
  'SELECT threat_type, SUM(threat_count) n
   FROM `my-gcp-project.gemini_ent_dashboard.v_model_armor_threats_long`
   GROUP BY threat_type ORDER BY n DESC'
```

### 7) 노트북 경로 (Terraform 대신 Python으로 단계별)
`notebook/gemini_enterprise_dashboard_setup.ipynb` 를 Colab/Jupyter에서 열고, 0단계의 `PROJECT_ID` 만 본인 프로젝트로 바꾼 뒤 위에서부터 실행. (각 셀 멱등, 비용 유발 셀은 플래그로 게이트)

### 8) 정리 (삭제)
```bash
terraform -chdir=terraform destroy -var project_id=my-gcp-project
# Log Analytics 활성화(_Default 버킷)는 null_resource라 destroy로 되돌리지 않음 — 필요시 수동
```

---

## 알아둘 제약

- **Forward-only**: Log Analytics는 활성화 시점 이후 로그만 인덱싱. 과거 로그 백필 불가 (Logs Explorer로 조회).
- **보관 90일**: `_Default` 버킷 90일 초과 로그는 `_AllLogs`에서도 사라짐.
- **Looker Studio 차트 생성 API 없음**: Looker Studio는 차트를 코드로 만드는 API가 없어, 템플릿을 1회 수동 제작 후 **Linking API 템플릿 복제**로 완성형 대시보드를 자동 배포(`looker_studio_setup.md` 섹션 0). 커스텀 별칭을 맨바닥에서 넣는 from-scratch 방식은 Looker Studio가 지원하지 않음.
- **엔드포인트**: 이 유형(gen-lang-client) 프로젝트에선 `gemini-2.5-flash-lite` / `gemini-2.5-flash`만 작동 확인됨.

자세한 내용은 [`AUTOMATION.md`](AUTOMATION.md) 와 [`terraform/README.md`](terraform/README.md) 참고.

---

## 라이선스

[Apache License 2.0](LICENSE) — 상업적 사용·수정·배포·특허 사용 허용. 자유롭게 사용하되 저작권/라이선스 고지를 유지하세요.

```
Copyright 2026 sykang169
Licensed under the Apache License, Version 2.0
```

## 기여

이슈·PR 환영합니다. 배포/구조 변경 시 `terraform validate` 통과와 문서 갱신을 함께 부탁드립니다.
