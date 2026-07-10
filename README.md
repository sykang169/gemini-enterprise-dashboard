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

# 3) Looker Studio 대시보드 구성 (looker_studio_setup.md 가이드 따라)
#    - 최초 1회: 뷰를 데이터 소스로 연결해 차트 배치 (섹션 0)
#    - 이후 자동: 그 리포트를 템플릿으로 등록하면 URL 하나로 완성형 대시보드 복제
```

`deploy.sh`가 하는 일: 결제/인증 preflight → 필요한 API 활성화 → BigQuery 데이터셋 → Log Analytics 링크 → BQ↔Gemini 연결·IAM → (IAM 전파 5분 대기 내장) → Gemini 원격 모델 → 대시보드 뷰 22개 → (옵션) 콘텐츠 분류·예약 쿼리 → **Looker Studio 구성 안내(또는 템플릿 지정 시 완성형 대시보드 복제 URL) 출력**.

> **Looker Studio 자동 생성:** Looker Studio는 차트를 코드로 맨바닥에서 만드는 API가 없어, 완성형 대시보드는 **템플릿 리포트 복제** 방식으로 자동화합니다. `looker_studio_setup.md` 섹션 0을 따라 한 번 템플릿을 만들고 `-var="looker_studio_template_report_id=<REPORT_ID>"`로 배포하면, 이후 어떤 프로젝트든 완성형 대시보드를 한 URL로 복제 생성합니다.

---

## 아키텍처

```
[Gemini Enterprise / Model Armor]
        │  Cloud Logging 실시간 자동 수집
        ▼
[_Default 로그 버킷 (Log Analytics 켜짐, 90일 보관)]
        │  federated (복사 없음, BigQuery 저장비 0)
        ▼
[gemini_ent_analytics._AllLogs]  ── SQL 뷰 22개 ──▶ [Looker Studio (무료)]
        │
        └─ (옵션) Model Armor 프롬프트 원문
             └─ BigQuery + Gemini(gemini-2.5-flash-lite) 분류
                  └─ 토픽/의도/감성 뷰  ← 매일 03:00 KST 예약 쿼리로 갱신
```

**핵심: 로그를 BigQuery로 스트리밍/복사하지 않습니다.** Log Analytics 연합 조회라 뷰는 항상 최신이고 로그 저장비가 없습니다. (콘텐츠 분류 테이블만 예약 쿼리로 배치 갱신)

---

## 대시보드 지표 (22개 뷰)

| 그룹 | 내용 | 내장 대비 |
|------|------|-----------|
| **운영** | 일별/유형별 쿼리, 에이전트 호출, DAU, 사용자당 쿼리, 시간대 히트맵 | 유사 |
| **🛡️ 보안** | Model Armor 차단율, 위협유형(폭력/혐오/성/CSAM/**프롬프트 인젝션**), verdict, 업무/비업무 분류 | **없음** |
| **⚡ 지연** | 응답 p50/p95 (trace 기반), 사용자·에이전트별 | **없음** |
| **📚 품질** | 그라운딩 커버리지(할루시네이션 리스크), 인용 출처 Top | **없음** |
| **🧠 콘텐츠** | 질문 토픽 분포, 의도, 감성(부정 급증 경보) — Gemini 분류 | **없음** |
| **👤 사용자** | 행 단위 드릴다운(user_id 필터) | 제한적 |

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
│   ├── 01_create_views.sql       # 뷰 22개 정의
│   └── 02_content_classification.sql  # Gemini 콘텐츠 분류 (옵션)
├── notebook/
│   └── gemini_enterprise_dashboard_setup.ipynb  # Python 대안 경로
└── terraform/                    # IaC (apply 한 번으로 전체 구성)
    ├── apis.tf · providers.tf · variables.tf · datasets.tf
    ├── logging.tf · connection.tf · model_and_views.tf
    ├── scheduled_query.tf · outputs.tf
    ├── terraform.tfvars.example
    └── README.md
```

---

## 옵션 & 비용

| 옵션 | 기본 | 설명 |
|------|------|------|
| `enable_content_classification` | `false` | Gemini로 질문 토픽/감성 분류 (행당 Gemini 호출 비용) |
| `enable_scheduled_classification` | `false` | 매일 03:00 KST 자동 재분류 (예약 쿼리) |

- **Log Analytics / 뷰 / Looker Studio**: 사실상 무료 (로그 보관비 + 소량 BQ 스캔)
- **콘텐츠 분류(옵션)**: `gemini-2.5-flash-lite` 사용으로 저비용. 분류한 건수만큼 과금

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
