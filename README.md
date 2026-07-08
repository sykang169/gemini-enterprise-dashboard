# Gemini Enterprise · 운영/보안/콘텐츠 대시보드

Gemini Enterprise + Model Armor의 Cloud Logging 로그를 **Log Analytics(무료 연합 조회) → BigQuery 뷰 → Looker Studio(무료)** 로 시각화하는 대시보드 솔루션입니다. 내장 애널리틱스가 못 보여주는 **보안(Model Armor·프롬프트 인젝션) · 응답 지연(SLO) · 그라운딩 신뢰도 · 콘텐츠 토픽/감성**까지 한 번의 `terraform apply`로 배포합니다.

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://console.cloud.google.com/cloudshell/open?cloudshell_git_repo=https://github.com/sykang169/gemini-enterprise-dashboard&cloudshell_tutorial=tutorial.md&cloudshell_workspace=.)

> 버튼을 누르면 Cloud Shell이 이 저장소를 클론하고 `tutorial.md` 대화형 가이드 패널을 띄웁니다. (Private 저장소라 소유자 계정으로 로그인 시 동작)

---

## 🚀 Quickstart (3단계)

```bash
# 1) 클론
git clone https://github.com/sykang169/gemini-enterprise-dashboard.git && cd gemini-enterprise-dashboard

# 2) 배포 (프로젝트 소유자/편집자 권한 + 결제 활성화 필요, ~7분)
./deploy.sh <YOUR_PROJECT_ID>

# 3) 출력된 Looker Studio URL 을 열어 차트 배치 (looker_studio_setup.md 가이드 따라)
```

`deploy.sh`가 하는 일: 필요한 API 5개 활성화 → BigQuery 데이터셋 → Log Analytics 링크 → BQ↔Gemini 연결·IAM → (IAM 전파 5분 대기 내장) → Gemini 원격 모델 → 대시보드 뷰 22개 → (옵션) 콘텐츠 분류·예약 쿼리 → **바로 열 수 있는 Looker Studio URL 출력**.

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
├── looker_studio_setup.md        # Looker Studio 차트 배치 가이드
├── looker_studio_create_url.txt  # 22개 뷰 프리커넥트 URL (생성물)
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

## 알아둘 제약

- **Forward-only**: Log Analytics는 활성화 시점 이후 로그만 인덱싱. 과거 로그 백필 불가 (Logs Explorer로 조회).
- **보관 90일**: `_Default` 버킷 90일 초과 로그는 `_AllLogs`에서도 사라짐.
- **Looker Studio 차트 배치는 수동**: Looker Studio는 IaC/API가 없어 프리커넥트 URL + `looker_studio_setup.md` 가이드로 대체.
- **엔드포인트**: 이 유형(gen-lang-client) 프로젝트에선 `gemini-2.5-flash-lite` / `gemini-2.5-flash`만 작동 확인됨.

자세한 내용은 [`AUTOMATION.md`](AUTOMATION.md) 와 [`terraform/README.md`](terraform/README.md) 참고.
