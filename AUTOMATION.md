# Gemini Enterprise + Model Armor Dashboard — Automation (IaC)

이 문서는 지금까지 수동으로 구축한 BigQuery/Looker Studio 대시보드를 재현/유지보수하기 위한
두 가지 자동화 산출물을 설명합니다: **Terraform**(선언적 IaC, "원큐 배포" 지원)과
**Jupyter/Colab 노트북**(절차적, 탐색/디버깅용). 실제 리소스는 이 커밋에서 생성되지 않았습니다 —
파일만 작성되었습니다.

## 🚀 원큐 배포 (TL;DR)

**신규/빈 프로젝트에서도** 아래 명령 **1개**로 전체 구성(API 활성화 → 데이터셋 → Log Analytics
연동 → 커넥션/IAM → 원격 모델 → 23개 뷰 → Looker Studio URL)이 끝까지 완료됩니다.
state는 로컬이 아니라 `gs://<PROJECT_ID>-tfstate`에 저장되므로(`backend.tf`) 다른 PC에서
같은 프로젝트에 재배포해도 변경분만 반영됩니다.

```bash
./deploy.sh <YOUR_PROJECT_ID>

# 질문·응답 원문 + 영구 보관까지 (권장 — 둘 다 소급 불가, 배포 전에 결정)
./deploy.sh <YOUR_PROJECT_ID> \
  -var="enable_sensitive_logging=true" \
  -var="enable_log_archive=true" -var="enable_scheduled_archive=true"
```

- **사전조건**: 대상 프로젝트에 **결제(billing) 활성화** + 실행 계정에 **프로젝트 소유자(Owner)
  또는 편집자(Editor)** 권한 (세분화된 역할 목록은 `terraform/README.md`의 Prerequisites 참고).
- **예상 소요 시간**: 약 **7분** — 대부분은 IAM 전파를 기다리는 의도된 5분 대기(`time_sleep`,
  아래 참고)이고, 나머지 API 활성화·리소스 생성은 수 초~1분 내외입니다.
- 완료되면 스크립트가 Looker Studio "새 보고서 만들기" URL을 바로 출력합니다.
- **다른 프로젝트에 배포할 때도 `project_id`만 바꾸면 됩니다** — `sql/01_create_views.sql` /
  `sql/02_content_classification.sql`에 하드코딩된 프로젝트 ID·데이터셋 이름은 Terraform이
  `model_and_views.tf`의 `replace()`로, 노트북은 `load_sql()` 헬퍼로 자동 치환해 주입합니다.
- **두 플래그는 소급이 안 됩니다**: `enable_sensitive_logging`을 안 켜면 질문·응답·사용자ID가
  `<elided>`로 굳고, `enable_log_archive`를 안 켜면 로그 버킷 리텐션(기본 30일)이 지난 데이터가
  사라집니다. 둘 다 **켠 시점 이후**에만 효력이 있으니 배포 전에 결정하세요.

## 산출물 지도

```
sql/
  01_create_views.sql          # 23개 뷰: 지표 뷰 21개 + v_log_source(차트용, 90일 윈도우)
                               #          + v_log_source_all(ad-hoc, 무제한). t_logs_archive 도 여기서 생성
  02_content_classification.sql # ② 콘텐츠 분류 (옵트인/비용 유발)
  03_archive_logs.sql          # ③ 로그 아카이브 — _AllLogs → t_logs_archive 증분 MERGE (옵트인)

terraform/
  providers.tf                 # google(~> 6.0) + time(~> 0.11) provider 핀
  backend.tf                   # GCS 원격 state (빈 블록 — 값은 deploy.sh가 init 시 주입)
  apis.tf                      # google_project_service (6개 API 자동 활성화) — 원큐 배포 핵심
  variables.tf                 # project_id(필수, 기본값 없음) 외 전부 기본값 있음, 옵트인 플래그·스케줄
  datasets.tf                  # google_bigquery_dataset.gemini_ent_dashboard
  logging.tf                   # Log Analytics 활성화(null_resource) + google_logging_linked_dataset
  connection.tf                # google_bigquery_connection.gemini_conn + IAM(aiplatform.user)
  model_and_views.tf           # time_sleep(IAM 전파 대기) + google_bigquery_job x3 (모델 DDL/뷰/옵트인 분류)
                               # + DASHBOARD_WINDOW_DAYS 치환
  sensitive_logging.tf         # 옵트인: 엔진 observabilityConfig PATCH (원문·사용자ID 마스킹 해제)
  archive.tf                   # 옵트인: t_logs_archive 생성·백필 + 매시간 증분 예약 쿼리
  scheduled_query.tf           # google_bigquery_data_transfer_config (옵트인, 콘텐츠 분류 스케줄 자동 실행)
  outputs.tf                   # 데이터셋/커넥션 id, 모델 엔드포인트, 예약 쿼리 id, Looker Studio 실행 URL
  terraform.tfvars.example     # project_id만 채우면 되는 최소 예시
  README.md                    # Quickstart·사용법·선행조건·한계 상세

notebook/
  gemini_enterprise_dashboard_setup.ipynb   # 0~6-B단계, 셀 단위 재현 (Colab/Jupyter)

deploy.sh                      # 루트: init+apply+Looker Studio URL 출력 원큐 래퍼
```

## 두 산출물의 관계

- **Terraform**은 선언적이고 재현 가능한 "단일 진실 공급원"으로 사용하세요. `sql/01_create_views.sql`을
  고치면 `google_bigquery_job.create_dashboard_views`의 `job_id`(SQL 해시 기반)가 바뀌어 재실행됩니다.
- **노트북**은 단계별로 눈으로 확인하며 실행하고 싶을 때, 디버깅할 때, 혹은 Terraform 도입 전
  빠르게 처음부터 재현해볼 때 사용하세요. 두 산출물 모두 **멱등**하게 작성되어 있어 반복 실행해도
  안전합니다(콘텐츠 분류 제외 — 아래 비용 주의 참고).
- 두 산출물을 동시에 프로덕션에 적용하지 마세요 (예: Terraform이 만든 job과 노트북이 만든 job이
  중복 실행될 수 있음). 하나를 운영 표준으로 정하고 다른 하나는 보조 도구로 쓰는 것을 권장합니다.

## 사용법

### Terraform

가장 간단한 방법 (원큐 배포 래퍼):

```bash
./deploy.sh <YOUR_PROJECT_ID>

# 질문·응답 원문 + 영구 보관까지 (권장 — 둘 다 소급 불가, 배포 전에 결정)
./deploy.sh <YOUR_PROJECT_ID> \
  -var="enable_sensitive_logging=true" \
  -var="enable_log_archive=true" -var="enable_scheduled_archive=true"
```

또는 Terraform을 직접:

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # project_id만 채우면 됨
terraform init
terraform plan
terraform apply
```

**Cloud Shell에서 열기**: 이 저장소가 공개 git URL을 가지면, 로컬에 `terraform`/`gcloud`를 설치할
필요 없이 아래 패턴의 URL을 브라우저로 열면 Cloud Shell이 저장소를 체크아웃한 채로 열립니다
(`gcloud`/`terraform`은 이미 설치·인증되어 있음):
`https://ssh.cloud.google.com/cloudshell/editor?cloudshell_git_repo=<REPO_URL>` — 이후 터미널에서
Quickstart 명령을 그대로 실행하면 됩니다.

상세 사용법·리소스 표·한계는 `terraform/README.md` 참고. **이 리포지토리를 작성하는 동안
`terraform init`/`plan`/`apply`는 실행하지 않았습니다** — `terraform fmt -check`와 `bash -n
deploy.sh`로 문법만 검증했습니다. 실제 적용 전 `terraform plan` 결과를 반드시 검토하세요.

### 노트북

Colab에서 열거나 로컬 Jupyter에서 리포지토리 루트를 기준으로 실행하세요 (0단계 셀이
`sql/01_create_views.sql` 경로를 자동 탐색합니다). 셀은 위에서 아래로 순서대로 실행합니다:

0. 변수 설정 (프로젝트/데이터셋/커넥션/모델 이름 + 인증)
1. Log Analytics 활성화 + linked dataset 생성 (멱등, forward-only 경고 포함)
2. 대시보드 데이터셋 생성 (멱등)
3. 뷰 생성 — `sql/01_create_views.sql` 실행 (멱등, `CREATE OR REPLACE VIEW`)
4. 커넥션 + IAM + 원격 모델 (멱등)
5. (옵트인, 기본 비활성화) 콘텐츠 분류 1회 실행 — `sql/02_content_classification.sql` 실행
6. Looker Studio 생성 URL 출력
6-B. (옵트인, 기본 비활성화) 콘텐츠 분류 **예약 쿼리**(매일 자동 실행) 생성 — 실환경에 이미 수동 생성된
     동일 목적 config(`transferConfigs/YOUR_TRANSFER_CONFIG_ID`)가 있으니, 켜기 전에
     노트북 셀의 중복 생성 경고를 반드시 읽을 것

## 선행 조건 (권한)

- **결제(billing)가 활성화된 프로젝트**여야 합니다 (BigQuery/Vertex AI/Log Analytics 모두 결제 필요).
- `terraform apply`(또는 `deploy.sh`) 혹은 노트북을 실행하는 계정에 대상 프로젝트의
  **소유자(Owner) 또는 편집자(Editor)** 권한을 권장합니다. 더 좁히려면:

| 역할 | 용도 |
|---|---|
| `roles/bigquery.admin` | 데이터셋/뷰/모델 생성, job 실행 |
| `roles/logging.admin` | Log Analytics 활성화, linked dataset 생성 |
| `roles/resourcemanager.projectIamAdmin` (또는 `roles/aiplatform.user`를 부여할 수 있는 좁은 권한) | 커넥션 서비스 계정에 Vertex AI 접근 권한 부여 |
| `roles/serviceusage.serviceUsageAdmin` | `terraform/apis.tf`가 API를 **자동으로 활성화**하므로, 단순 소비(consumer) 권한이 아니라 활성화(admin) 권한이 필요 |

API는 더 이상 수동으로 미리 활성화할 필요가 없습니다 — `terraform/apis.tf`가
`bigquery.googleapis.com`, `bigqueryconnection.googleapis.com`, `logging.googleapis.com`,
`aiplatform.googleapis.com`, `bigquerydatatransfer.googleapis.com` 5개를 apply 시작 시점에
자동으로 활성화하고, 다른 모든 리소스는 이 활성화가 끝난 뒤에 실행되도록 `depends_on`으로
묶여 있습니다. (노트북으로 수동 재현할 경우에는 이 자동화가 없으므로 API를 직접 활성화해야 합니다.)

## 중요한 주의사항

1. **Forward-only (되돌릴 수 없음)**: Log Analytics는 활성화된 시점 이후의 로그만
   `gemini_ent_analytics._AllLogs`에 인덱싱합니다. 과거 로그는 절대 백필되지 않으며, 이는
   Terraform이나 노트북이 아니라 Cloud Logging 자체의 제약입니다. 이미 이 프로젝트에서는
   2026-07-08 활성화 시점 이전 로그는 조회되지 않습니다.
2. **로그 보관 기간(retention) — 90일**: `_Default` 로그 버킷의 `retentionDays`는 현재 **90일**입니다
   (`gcloud logging buckets describe _Default --location=global`로 재확인 가능). `terraform/logging.tf`의
   `google_logging_project_bucket_config` 대안 예시 주석도 이 값(90)으로 맞춰뒀습니다 — 실제로 그
   네이티브 리소스를 쓰기로 결정하면 반드시 최신 값을 다시 조회해 맞추세요(값이 바뀔 수 있음).
3. **모델 엔드포인트 — Flash-Lite로 비용 절감**: 원격 모델 `gemini_flash`는 기본적으로
   `gemini-2.5-flash-lite` 엔드포인트를 사용합니다(Terraform `var.gemini_endpoint`, 노트북
   `MODEL_ENDPOINT`). **실측 확인**: 이 프로젝트(`YOUR_PROJECT_ID`)에서
   `gemini-2.0-flash`, `gemini-2.0-flash-lite`, `gemini-2.0-flash-001`은 모두 "not found"로
   실패하며, `gemini-2.5-flash-lite`와 `gemini-2.5-flash`만 작동이 확인되었습니다. 재검증 없이
   2.0 계열로 되돌리지 마세요.
4. **비용 (② 콘텐츠 분류, 1회성 vs 예약 쿼리)**: `sql/02_content_classification.sql`은 아직 분류되지
   않은 프롬프트 행마다 `ML.GENERATE_TEXT`(Gemini) 호출을 1회 발생시킵니다. 증분 실행(이미 분류된
   timestamp는 제외)이지만, 새 로그가 쌓일 때마다 실행 비용이 계속 발생합니다.
   - **1회성**: Terraform `enable_content_classification`(기본 `false`) / 노트북
     `RUN_CONTENT_CLASSIFICATION`(기본 `False`) — apply/셀 실행 시점에 1회만 돌립니다.
   - **예약 쿼리(매일 자동)**: Terraform `enable_scheduled_classification`(기본 `false`, 리소스는
     `scheduled_query.tf`) / 노트북 `ENABLE_SCHEDULED_CLASSIFICATION`(기본 `False`, 6-B 단계) —
     BigQuery Data Transfer Service로 `var.scheduled_query_schedule`(기본 **`"every day 18:00"`**)
     스케줄을 등록해 자동화합니다. **스케줄은 항상 UTC 기준**이라 18:00은 UTC 18:00 = **KST
     03:00**(다음날)을 의미합니다. 선행 조건인 `bigquerydatatransfer.googleapis.com` API는
     `terraform/apis.tf`가 자동 활성화합니다.
   - ⚠️ **이미 실환경에 동일 목적의 예약 쿼리가 수동으로 생성되어 있습니다**
     (`projects/YOUR_PROJECT_NUMBER/locations/us/transferConfigs/YOUR_TRANSFER_CONFIG_ID`,
     location `us`, Compute Engine 기본 서비스 계정, 스케줄이 `every 24 hours`에서 **`every day
     18:00`(UTC)로 이미 갱신됨**). `enable_scheduled_classification`을 켜기 전에 이 config를
     `terraform import`로 가져오거나, 노트북 6-B 셀의 중복 검사 로직을 통해 기존 config가 있는지
     먼저 확인하세요 — 그렇지 않으면 분류 스크립트가 이중 실행/이중 과금됩니다.
5. **`t_content_topics`는 자동 최신화되지 않습니다**: `sql/01_create_views.sql`의 `v_*` 뷰들은 매번
   조회 시점 기준으로 계산되는 라이브 `SELECT`라 항상 최신이지만, `t_content_topics`는 append-only
   테이블이라 위 4번의 1회성 job 또는 예약 쿼리 중 하나가 주기적으로 실행돼야만 새 로그가 분류됩니다.
   이를 자동화하는 것이 바로 `scheduled_query.tf`(및 노트북 6-B)의 목적입니다.
6. **BigQuery job의 불변성**: `google_bigquery_job`은 한 번 생성되면 수정할 수 없는 리소스라서,
   `job_id`를 SQL 텍스트의 해시로 파생시켰습니다 — SQL을 바꾸면 새 job이 생성되어 실제로
   재실행되고, 바꾸지 않으면 `terraform plan`에 변경사항이 없습니다(진짜 멱등).
7. **`_Default` 로그 버킷은 프로젝트에 하나뿐인 공유 리소스**입니다. `logging.tf`는 일부러
   `google_logging_project_bucket_config`(네이티브 리소스, `enable_analytics` 필드가 실제로
   존재함)를 쓰지 않고 `null_resource` + `local-exec`로 좁게 범위를 제한했습니다 — 이유는
   `terraform/README.md`의 `logging.tf` 주석 참고.
8. **뷰 SQL은 라이브 환경에서 추출한 것**입니다 (`bq show --view --format=prettyjson`). 향후 콘솔에서
   뷰를 직접 수정하면 `sql/01_create_views.sql`과 실제 정의가 어긋날 수 있으니, 변경은 이 파일을
   고치고 Terraform/노트북으로 재적용하는 방식으로 관리하는 것을 권장합니다. `sql/01_create_views.sql`
   / `sql/02_content_classification.sql` / `sql/03_archive_logs.sql`은 원본 프로젝트
   (`YOUR_PROJECT_ID`)와 기본 데이터셋 이름이 그대로 하드코딩되어 있어 **다른 프로젝트에 배포할 때
   그대로 두면 깨집니다** — Terraform은 `model_and_views.tf`의 중첩 `replace()`로, 노트북은
   `load_sql()` 헬퍼로 apply/실행 시점에 `var.project_id`/`PROJECT_ID`(및 데이터셋 변수, Terraform
   한정)로 자동 치환하므로 SQL 파일 자체를 고칠 필요는 없습니다.
   **단 `sql/01_create_views.sql`은 `bq query < sql/01_create_views.sql` 식의 단독 실행이
   불가능합니다** — `v_log_source`에 `INTERVAL DASHBOARD_WINDOW_DAYS DAY` 토큰이 있어 그대로는
   파싱되지 않습니다(`Unrecognized name: DASHBOARD_WINDOW_DAYS`). 토큰은 Terraform이
   `var.dashboard_window_days`로, 노트북이 `DASHBOARD_WINDOW_DAYS` 상수로 렌더합니다(둘의 렌더
   결과가 바이트 단위로 동일함을 확인). 손으로 실행하려면 프로젝트 id와 함께 이 절도 치환하세요:
   `sed -e 's/YOUR_PROJECT_ID/<PROJ>/g' -e 's/INTERVAL DASHBOARD_WINDOW_DAYS DAY/INTERVAL 90 DAY/' sql/01_create_views.sql | bq query --use_legacy_sql=false`
   `sql/02`·`sql/03`은 프로젝트 id만 치환하면 단독 실행됩니다.
9. **API 자동 활성화 (원큐 배포 핵심)**: `terraform/apis.tf`의 `google_project_service.apis`가
   apply 시작 시점에 6개 API를 전부 활성화하고, 다른 모든 리소스가 `depends_on`으로 이를 기다립니다.
   `disable_on_destroy = false`라서 `terraform destroy`가 API를 비활성화하지 않습니다(공유 프로젝트에서
   안전하게).
10. **IAM 전파 대기 (원큐 배포 신뢰성 핵심)**: 실측 결과, 커넥션 서비스 계정에
    `roles/aiplatform.user`를 부여한 직후 곧바로 원격 모델을 생성하면 **permission 오류로 실패**합니다
    (전파에 5분 이상 소요). `model_and_views.tf`의 `time_sleep.wait_for_iam_propagation`
    (`create_duration = "300s"`)이 IAM 부여와 모델 생성 job 사이에 강제 대기를 넣어, 빈 프로젝트에서도
    `terraform apply` 한 번으로 끝까지 성공하도록 만듭니다. 이 5분이 원큐 배포 전체 소요시간(~7분)의
    대부분을 차지합니다.

## 검증 상태

- `sql/01_create_views.sql`: 초기 지표 뷰 20개는 `bq show --view --format=prettyjson`으로 라이브에서 추출(이후 v_agent_page_views 등은 직접 작성), 대상 프로젝트/데이터셋
  일치 확인.
- `terraform/*.tf`: `terraform fmt -check -diff -recursive` 통과 (문법/스타일 정상, `apis.tf`/`scheduled_query.tf`/
  `outputs.tf`의 `for`/`flatten` 표현식, `model_and_views.tf`의 중첩 `replace()` 표현식 포함).
  `terraform init -backend=false && terraform validate`도 통과 확인(provider 스키마 기준 문법 검증만—
  자격 증명/state 없이 실행되어 실제 GCP 접근이나 리소스 변경은 없음). `plan`/`apply`는 여전히
  실행하지 않았습니다.
- `deploy.sh`: `bash -n`으로 문법 검증 통과, 실행 권한 부여(`chmod +x`)만 하고 실제 실행은 하지 않음.
- `notebook/gemini_enterprise_dashboard_setup.ipynb`: `nbformat.validate()` 통과 (nbformat 4.5, 23개 셀).
- 읽기 전용 조회로 실측: `_Default` 버킷 `retentionDays: 90`, 기존 예약 쿼리
  `transferConfigs/YOUR_TRANSFER_CONFIG_ID` 존재 확인 (스케줄 `every day 18:00` UTC로
  갱신된 상태로 반영).
