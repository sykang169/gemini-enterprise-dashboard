# Gemini Enterprise 대시보드 배포

<walkthrough-tutorial-duration duration="10"></walkthrough-tutorial-duration>

이 가이드는 Gemini Enterprise + Model Armor 로그 대시보드를 **한 번의 명령으로** 배포합니다.

## 프로젝트 선택

먼저 배포할 GCP 프로젝트를 선택하세요. (프로젝트 소유자/편집자 권한 + 결제 활성화 필요)

<walkthrough-project-setup></walkthrough-project-setup>

```bash
gcloud config set project <walkthrough-project-id/>
```

## 사전 확인

Terraform이 Cloud Shell에 기본 설치되어 있습니다. 버전을 확인하세요.

```bash
terraform version
```

배포 스크립트에 실행 권한을 부여합니다.

```bash
chmod +x deploy.sh
```

**결제(billing)가 활성화된 프로젝트여야 합니다.** BigQuery·Log Analytics는 결제 없이는 동작하지 않습니다. 확인하세요 — `billingEnabled: true`가 떠야 합니다.

```bash
gcloud billing projects describe <walkthrough-project-id/>
```

`false`이면 결제 계정을 연결하세요.

```bash
gcloud billing accounts list
gcloud billing projects link <walkthrough-project-id/> --billing-account=<ACCOUNT_ID>
```

## 질문·응답 원문 로깅 (지금 결정하세요)

**이 선택은 배포 전에 해야 합니다. 나중에 켜면 소급이 안 됩니다.**

Gemini Enterprise는 기본적으로 로그의 민감 필드를 `<elided>`로 마스킹합니다. 즉 **끄고 배포하면** 질문·응답·사용자ID가 전부 가려진 채 쌓이고, 나중에 켜도 **그 기간 데이터는 영구히 복구할 수 없습니다.**

마스킹 상태에서 비어버리는 지표:

| 뷰 | 마스킹 시 증상 |
| --- | --- |
| `v_user_questions` | 질문·응답이 통째로 비어 있음 |
| `v_queries_per_user` | 전체가 `<elided>` 사용자 1명으로 합쳐짐 |
| `v_daily_active_users` | 활성 사용자가 항상 1 |
| `v_user_activity_detail` / `v_user_agent_trace` | 사용자 드릴다운 불가 |
| 콘텐츠 분류(아래 단계) | 분류할 질문 텍스트가 없어 무의미 |

**⚠️ 켜면 최종 사용자의 질문 원문과 신원이 평문으로** Cloud Logging에 기록되고 BigQuery로 복사됩니다. 실제 PII입니다. 켜기로 했다면 배포 후 `gemini_ent_analytics` / `gemini_ent_dashboard` 데이터셋의 IAM을 프롬프트 열람 권한자에게만 열어두세요.

- **켠다** → 다음 단계에서 `-var="enable_sensitive_logging=true"`를 붙여 배포
- **끈다** → 그대로 배포. 사용량·보안 지표는 정상 작동하고, 질문 내용 관련 지표만 빕니다

기본 동작은 **이미 로그를 내보내고 있는 엔진만** 골라서 마스킹을 풀어줍니다. 즉 새로 로그가 발생하지도, 청구가 늘지도 않고, 지금 `<elided>`로 들어오던 행이 원문으로 바뀔 뿐입니다. 관측성이 꺼진 엔진은 건너뛰고 목록으로 알려줍니다.

<walkthrough-footnote>아직 관측성을 한 번도 안 켠 새 앱이라면, 엔진을 직접 지정해야 이 모듈이 관측성까지 켜줍니다: <code>-var='sensitive_logging_engine_ids=["엔진ID"]'</code>. 엔진 ID는 배포 로그의 skipped 목록에 표시됩니다.</walkthrough-footnote>

## 배포 실행

아래 명령이 전체 인프라를 구성합니다 — API 활성화, BigQuery 데이터셋/뷰, Log Analytics 링크, Gemini 연결·모델까지. **IAM 전파 대기 때문에 약 7분** 걸립니다.

`deploy.sh`는 다음을 자동으로 처리합니다: 메타데이터 토큰 우회, `serviceusage`/`cloudresourcemanager` 부트스트랩, 이미 존재하는 리소스 import(재실행 안전), 일시적 오류 시 최대 3회 재시도.

**질문·응답 원문까지 수집하려면** (앞 단계에서 "켠다"를 골랐다면):

```bash
./deploy.sh <walkthrough-project-id/> -var="enable_sensitive_logging=true"
```

**사용량·보안 지표만 원하면**:

```bash
./deploy.sh <walkthrough-project-id/>
```

<walkthrough-footnote>중간에 IAM 전파 대기(약 5분) 단계에서 멈춘 것처럼 보여도 정상입니다. 기다려 주세요.</walkthrough-footnote>

## (선택) 콘텐츠 분류 활성화

사용자 질문의 토픽/감성 분석까지 원하면, 아래처럼 옵션 플래그를 켜서 다시 적용하세요. (Gemini 호출 비용 발생)

**전제조건: 앞의 "질문·응답 원문 로깅"을 켰어야 합니다.** 분류 대상이 질문 원문이라, 마스킹 상태에서는 분류할 것이 없어 빈 결과만 나옵니다.

```bash
terraform -chdir=terraform apply \
  -var project_id=<walkthrough-project-id/> \
  -var enable_sensitive_logging=true \
  -var enable_content_classification=true \
  -var enable_scheduled_classification=true
```

이렇게 하면 매일 03:00(KST) 자동으로 신규 질문을 분류합니다.

## Looker Studio 대시보드 만들기

Looker Studio는 차트가 배치된 리포트를 코드로 맨바닥에서 만드는 API가 없습니다. 따라서 **최초 1회는 손으로** 만들고, 이후엔 그 리포트를 템플릿 삼아 자동 복제합니다.

<walkthrough-editor-open-file filePath="looker_studio_setup.md">looker_studio_setup.md</walkthrough-editor-open-file> **섹션 0**을 따라:
1. [lookerstudio.google.com](https://lookerstudio.google.com) → 빈 보고서 → **데이터 추가 → BigQuery → 이 프로젝트 → `gemini_ent_dashboard`** → 뷰들 연결
2. **섹션 A(보안·지연·품질·콘텐츠)를 첫 페이지로** 차트 배치

### 다음 프로젝트부터 자동 생성
위 리포트의 각 데이터 소스 별칭을 뷰 이름으로 맞추고 report id를 복사한 뒤:

```bash
terraform -chdir=terraform apply \
  -var project_id=<walkthrough-project-id/> \
  -var looker_studio_template_report_id=<REPORT_ID>
terraform -chdir=terraform output -raw looker_studio_url
```

출력된 URL을 열면 차트까지 완성된 대시보드가 자동 생성됩니다.

## 완료 🎉

<walkthrough-conclusion-trophy></walkthrough-conclusion-trophy>

대시보드 인프라 배포가 끝났습니다.

- 데이터는 배포 시점 이후부터 누적됩니다 (forward-only)
- 뷰는 Log Analytics 연합 조회라 **항상 최신**입니다
- 질문·응답 원문 로깅을 껐다면 `v_user_questions`는 비어 있는 게 정상입니다. 지금이라도 켜면 **켠 시점 이후** 질문부터 쌓입니다: `./deploy.sh <walkthrough-project-id/> -var="enable_sensitive_logging=true"`
- 정리하려면: `terraform -chdir=terraform destroy -var project_id=<walkthrough-project-id/>`

자세한 내용은 <walkthrough-editor-open-file filePath="README.md">README.md</walkthrough-editor-open-file> 를 참고하세요.
