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

## 배포 실행

아래 명령이 전체 인프라를 구성합니다 — API 활성화, BigQuery 데이터셋/뷰, Log Analytics 링크, Gemini 연결·모델까지. **IAM 전파 대기 때문에 약 7분** 걸립니다.

`deploy.sh`는 다음을 자동으로 처리합니다: 메타데이터 토큰 우회, `serviceusage`/`cloudresourcemanager` 부트스트랩, 이미 존재하는 리소스 import(재실행 안전), 일시적 오류 시 최대 3회 재시도.

```bash
./deploy.sh <walkthrough-project-id/>
```

<walkthrough-footnote>중간에 IAM 전파 대기(약 5분) 단계에서 멈춘 것처럼 보여도 정상입니다. 기다려 주세요.</walkthrough-footnote>

## (선택) 콘텐츠 분류 활성화

사용자 질문의 토픽/감성 분석까지 원하면, 아래처럼 옵션 플래그를 켜서 다시 적용하세요. (Gemini 호출 비용 발생)

```bash
terraform -chdir=terraform apply \
  -var project_id=<walkthrough-project-id/> \
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
- 정리하려면: `terraform -chdir=terraform destroy -var project_id=<walkthrough-project-id/>`

자세한 내용은 <walkthrough-editor-open-file filePath="README.md">README.md</walkthrough-editor-open-file> 를 참고하세요.
