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

## (선택) Model Armor 연결 — 보안 지표 10개의 전제

대시보드 지표 24개 중 **10개가 Model Armor 로그에 의존**합니다(차단율, 위협유형, 프롬프트 인젝션, verdict, 업무/비업무 분류). MA를 안 붙이면 이 뷰들은 **배포는 되지만 영원히 빈 채로** 남습니다. 이 모듈은 MA를 자동 구성하지 않으니, 보안 지표가 필요하면 아래를 먼저 하세요.

**1) API 활성화 + 권한** — `roles/modelarmor.admin`이 필요합니다.

```bash
gcloud services enable modelarmor.googleapis.com --project=<walkthrough-project-id/>
```

**2) 템플릿 생성** — ⚠️ **`--template-metadata-log-sanitize-operations`가 이 대시보드의 생명줄입니다.** 이 플래그가 없으면 MA는 검사만 하고 **로그를 안 남겨** 위 10개 뷰가 영원히 빕니다. 기본값이 아니니 반드시 넣으세요.

```bash
gcloud model-armor templates create ge-dashboard-armor \
  --project=<walkthrough-project-id/> \
  --location=us \
  --rai-settings-filters='[{"filterType":"HATE_SPEECH","confidenceLevel":"MEDIUM_AND_ABOVE"},{"filterType":"HARASSMENT","confidenceLevel":"MEDIUM_AND_ABOVE"},{"filterType":"DANGEROUS","confidenceLevel":"MEDIUM_AND_ABOVE"},{"filterType":"SEXUALLY_EXPLICIT","confidenceLevel":"MEDIUM_AND_ABOVE"}]' \
  --pi-and-jailbreak-filter-settings-enforcement=enabled \
  --pi-and-jailbreak-filter-settings-confidence-level=MEDIUM_AND_ABOVE \
  --malicious-uri-filter-settings-enforcement=enabled \
  --template-metadata-log-sanitize-operations
```

<walkthrough-footnote><b>location 주의</b>: 템플릿은 Gemini Enterprise 인스턴스와 <b>같은 프로젝트·같은 location</b>이어야 합니다. 이 저장소의 기본 배포 대상은 <code>us</code>입니다(BigQuery 데이터셋과 동일). REST로 직접 만들 때는 호스트가 리전형입니다 — <code>https://modelarmor.<b>us</b>.rep.googleapis.com/v1/projects/&lt;P&gt;/locations/us/templates?template_id=ge-dashboard-armor</code>. 프롬프트용/응답용 템플릿을 나눠 쓸 수도 있습니다.</walkthrough-footnote>

**3) Gemini Enterprise에 연결** — 설정은 engine이 아니라 그 아래 **assistant**에 붙습니다. gcloud 명령이 없어 REST로 PATCH합니다.

```bash
PROJ=<walkthrough-project-id/>
ENGINE=<YOUR_ENGINE_ID>    # 예: gemini-enterprise-1782188315701
TPL="projects/$PROJ/locations/us/templates/ge-dashboard-armor"

curl -X PATCH \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "X-Goog-User-Project: $PROJ" \
  -H "Content-Type: application/json" \
  -d "{\"customerPolicy\":{\"modelArmorConfig\":{
        \"userPromptTemplate\":\"$TPL\",
        \"responseTemplate\":\"$TPL\",
        \"failureMode\":\"FAIL_OPEN\"}}}" \
  "https://discoveryengine.googleapis.com/v1alpha/projects/$PROJ/locations/global/collections/default_collection/engines/$ENGINE/assistants/default_assistant?updateMask=customerPolicy.modelArmorConfig"
```

- `failureMode`: `FAIL_OPEN`(MA 장애 시 통과) / `FAIL_CLOSED`(차단). 가용성이 우선이면 전자, 보안이 우선이면 후자.
- `updateMask`는 **leaf 경로**(`customerPolicy.modelArmorConfig`)를 씁니다. 상위인 `customerPolicy`만 주면 그 객체 전체가 교체돼 다른 정책이 조용히 사라집니다.
- `X-Goog-User-Project` 헤더는 **빼면 안 됩니다.** discoveryengine은 quota project를 요구하는데, `gcloud auth print-access-token`으로 뽑은 토큰만 든 curl에는 그게 실려가지 않습니다(gcloud는 명령 실행 시 `core/project`를 읽어 알아서 붙여주지만, 토큰 자체에는 없습니다). 헤더가 없으면 API가 이 호출을 **gcloud CLI 자신의 클라이언트 프로젝트**(`32555940559`)로 귀속시키고 403 `SERVICE_DISABLED`를 돌려줍니다 — "내 프로젝트에 API가 꺼졌다"거나 "권한이 없다"처럼 읽히지만 둘 다 아닙니다. (서비스 계정 토큰은 자기 프로젝트를 갖고 있어 이 문제가 안 나타납니다. Cloud Shell처럼 **사용자 계정**으로 실행할 때만 터지는 이유입니다.)
- 위 헤더를 쓰려면 `$PROJ`에 대한 `serviceusage.services.use` 권한이 필요합니다. 없으면 403이 `USER_PROJECT_DENIED`로 바뀝니다(consumer가 `32555940559`가 아니라 `$PROJ`로 나오면 헤더는 제대로 간 것이고, 권한만 없는 상태입니다). 프로젝트 오너면 이미 포함돼 있고, 아니면:
  ```bash
  gcloud projects add-iam-policy-binding $PROJ \
    --member="user:$(gcloud config get-value account)" \
    --role="roles/serviceusage.serviceUsageConsumer"
  ```
- 엔진 ID는 `gcloud`로 확인: `curl -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "X-Goog-User-Project: $PROJ" "https://discoveryengine.googleapis.com/v1alpha/projects/$PROJ/locations/global/collections/default_collection/engines"`

**4) 확인** — 붙었는지 되읽어봅니다.

```bash
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "X-Goog-User-Project: $PROJ" \
  "https://discoveryengine.googleapis.com/v1alpha/projects/$PROJ/locations/global/collections/default_collection/engines/$ENGINE/assistants/default_assistant" \
  | grep -A5 customerPolicy
```

<walkthrough-footnote>Search 전용 앱에는 <code>default_assistant</code>가 없어 404가 납니다(어시스턴트 대화가 없으니 정상). MA는 어시스턴트가 있는 앱에만 붙습니다. 연결 후 앱에서 질문을 하나 던지면 몇 분 뒤 <code>v_model_armor_block</code>에 행이 쌓이기 시작합니다.</walkthrough-footnote>

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
./deploy.sh <walkthrough-project-id/> \
  -var="enable_sensitive_logging=true" \
  -var="enable_log_archive=true" -var="enable_scheduled_archive=true"
```

**사용량·보안 지표만 원하면**:

```bash
./deploy.sh <walkthrough-project-id/> \
  -var="enable_log_archive=true" -var="enable_scheduled_archive=true"
```

<walkthrough-footnote><b>아카이브 플래그를 왜 같이 켜나:</b> 뷰는 로그 버킷을 보는 창일 뿐이라 버킷 리텐션(기본 30일)이 지나면 데이터가 사라지고 백필이 없습니다. 아카이브는 뷰가 읽는 로그만 골라 복사해 이를 막습니다(38일 기준 20.6GB→11MB, 사실상 무료). 이것도 <b>미리</b> 켜야 의미가 있습니다.</walkthrough-footnote>

<walkthrough-footnote>중간에 IAM 전파 대기(약 5분) 단계에서 멈춘 것처럼 보여도 정상입니다. 기다려 주세요.</walkthrough-footnote>

## 기존 로그 가져오기 (설치 전 데이터)

**설치하기 전에 쌓인 로그도 대시보드에 나옵니다.** 단, 로그 버킷에 **아직 남아 있는 것**만입니다.

- Log Analytics를 켜면 `_AllLogs`는 켜기 **전에** 들어온 로그까지 포함해 버킷에 남은 로그를 모두 보여줍니다. 실측: `2026-07-08`에 켠 프로젝트에서 켜기 19일 전인 `2026-06-19`(보관 90일의 시작일)부터 날짜 공백 없이 조회됐습니다(감사 로그로 활성화 시각 확인).
- 차트는 `_AllLogs`가 아니라 아카이브(`t_logs_archive`)를 읽습니다. 앞 단계에서 `enable_log_archive=true`로 배포했다면 **첫 아카이브 실행이 아카이브가 비어 있음을 보고 버킷에 남은 기간 전체를 자동으로 복사**합니다. 따로 할 일은 없습니다.
- 보관 기간이 지난 로그는 어떤 방법으로도 되살릴 수 없습니다. 원문 로깅을 켜기 전 질문은 `<elided>`로, Model Armor를 연결하기 전 기간은 비어 있는 상태로 들어옵니다.

**1) 가져온 범위 확인** — 두 결과의 `oldest`가 비슷하면 끝입니다(아카이브는 대시보드가 읽는 로그만 담아 건수가 훨씬 적은 게 정상입니다).

```bash
PROJ=<walkthrough-project-id/>
bq query --use_legacy_sql=false --project_id=$PROJ \
  "SELECT 'bucket' src, MIN(timestamp) oldest, COUNT(*) n FROM \`$PROJ.gemini_ent_analytics._AllLogs\`
   UNION ALL
   SELECT 'archive', MIN(timestamp), COUNT(*) FROM \`$PROJ.gemini_ent_dashboard.t_logs_archive\`"
```

**2) (필요할 때만) 전체 기간 다시 가져오기** — 아카이브의 `oldest`가 버킷보다 한참 늦다면, 아카이브에 이미 행이 있던 상태에서 켜져 최근 것만 복사된 경우입니다(증분 실행은 아카이브의 최신 시각 기준 3시간 전부터만 읽습니다). 같은 `sql/03`을 **시작 시점만 1970년으로 바꿔** 한 번 돌리면 버킷에 남은 전체 기간을 채웁니다. 중복키 MERGE라 이미 있는 행은 다시 들어가지 않습니다.

```bash
PROJ=<walkthrough-project-id/>
sed -e "s/YOUR_PROJECT_ID/$PROJ/g" \
    -e 's/DECLARE lookback TIMESTAMP DEFAULT TIMESTAMP_SUB(watermark, INTERVAL 3 HOUR);/DECLARE lookback TIMESTAMP DEFAULT TIMESTAMP("1970-01-01");/' \
    sql/03_archive_logs.sql > /tmp/backfill_archive.sql
grep -q 'TIMESTAMP("1970-01-01");' /tmp/backfill_archive.sql && \
  bq query --use_legacy_sql=false --project_id=$PROJ < /tmp/backfill_archive.sql
```

<walkthrough-footnote><b>비용:</b> 버킷 전체 기간의 모든 로그를 한 번 스캔합니다. 실측 90일치 최대 약 11GB(dry-run 상한, 온디맨드 기준 1달러 미만). <code>grep -q</code>는 sed 치환이 실제로 됐는지 확인하는 안전장치입니다 — 실패하면 평소처럼 3시간치만 돌기 때문입니다. 매시간 예약 실행과 겹쳐 <code>concurrent update</code> 오류가 나면 그냥 다시 실행하세요.</walkthrough-footnote>

<walkthrough-footnote><b>아직 남은 로그를 더 오래 지키려면</b> 보관 기간을 늘리세요. 이미 지난 로그는 안 돌아오지만 지금 버킷에 있는 로그는 그만큼 더 남습니다(30일 초과분은 로그 보관비 발생): <code>gcloud logging buckets update _Default --location=global --retention-days=90</code></walkthrough-footnote>

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

## (선택) 과거 질문 분류

분류는 "아직 분류 안 된 질문"을 찾아 처리하므로(`t_content_topics`와 anti-join), **위 apply의 첫 실행이 버킷에 남아 있는 과거 질문까지 한꺼번에 분류합니다.** 대부분은 여기서 끝입니다.

남는 경우는 하나입니다: **버킷 보관 기간은 지났지만 아카이브에는 남아 있는 질문**(예: 아카이브는 몇 달 전부터 켜 뒀는데 분류는 지금 켠 경우). 기본 분류 쿼리는 버킷(`_AllLogs`)만 읽어서 이 질문들을 못 봅니다. 아래처럼 **읽는 곳을 아카이브로 바꿔** 돌리면 됩니다.

**1) 분류할 건수부터 확인** — Gemini 호출 1건 = 질문 1건이라, 이 숫자가 곧 비용입니다.

```bash
PROJ=<walkthrough-project-id/>
bq query --use_legacy_sql=false --project_id=$PROJ "
SELECT FORMAT_TIMESTAMP('%Y-%m', timestamp) month,
  COUNTIF(q IS NOT NULL AND q != '<elided>') to_classify,
  COUNTIF(q = '<elided>') masked
FROM (
  SELECT a.timestamp,
    COALESCE(JSON_VALUE(json_payload, '\$.request.query'),
      (SELECT STRING_AGG(JSON_VALUE(p, '\$.text'), '\n')
         FROM UNNEST(JSON_QUERY_ARRAY(json_payload, '\$.request.query.parts')) p)) q
  FROM \`$PROJ.gemini_ent_dashboard.t_logs_archive\` a
  WHERE log_name LIKE '%gemini_enterprise_user_activity'
    AND JSON_VALUE(json_payload, '\$.logMetadata.methodName') IN ('Search','StreamAssist')
    AND NOT EXISTS (SELECT 1 FROM \`$PROJ.gemini_ent_dashboard.t_content_topics\` t
                    WHERE t.timestamp = a.timestamp))
GROUP BY month ORDER BY month"
```

`masked`는 원문 로깅을 켜기 전 질문이라 분류할 수 없습니다(소급 불가).

**2) 기간을 정해 아카이브에서 분류** — 같은 `sql/02`에서 읽는 테이블과 기간만 바꿉니다. 건수가 많으면 한 번에 다 돌리지 말고 **월 단위로 나눠** 실행하세요(쿼리 한 건은 6시간 제한이 있고, 실측 평균 실행 시간이 이미 87분입니다).

```bash
PROJ=<walkthrough-project-id/>
FROM_TS=2026-06-01   # 포함
TO_TS=2026-07-01     # 제외
sed -e "s/YOUR_PROJECT_ID/$PROJ/g" \
    -e 's/gemini_ent_analytics\._AllLogs/gemini_ent_dashboard.t_logs_archive/' \
    -e "s/WHERE log_name LIKE '%gemini_enterprise_user_activity'/WHERE timestamp >= TIMESTAMP('$FROM_TS') AND timestamp < TIMESTAMP('$TO_TS') AND log_name LIKE '%gemini_enterprise_user_activity'/" \
    sql/02_content_classification.sql > /tmp/classify_history.sql
grep -q "t_logs_archive" /tmp/classify_history.sql && grep -q "TIMESTAMP('$FROM_TS')" /tmp/classify_history.sql && \
  bq query --use_legacy_sql=false --project_id=$PROJ < /tmp/classify_history.sql
```

<walkthrough-footnote><b>안전한 이유:</b> 이미 분류된 질문은 Gemini를 호출하기 전에 걸러지고(anti-join), 결과는 <code>timestamp</code> 기준 MERGE라 같은 기간을 다시 돌리거나 매일 예약 실행과 겹쳐도 중복 행이 생기지 않습니다. 두 <code>grep -q</code>는 치환이 실패해 <b>기간 제한 없이 전체를 분류하는 사고</b>를 막는 안전장치입니다. 분류 결과는 바로 <code>v_topic_distribution</code> · <code>v_intent_distribution</code> · <code>v_sentiment_daily</code>에 반영됩니다.</walkthrough-footnote>

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

- 설치 전 로그도 **버킷에 남아 있던 기간만큼** 함께 보입니다. 보관 기간이 지난 로그는 복구할 수 없습니다
- 차트는 아카이브를 읽어 **최대 1시간 늦게** 갱신됩니다(모든 지표가 일별 집계라 읽히는 값은 같습니다)
- 질문·응답 원문 로깅을 껐다면 `v_user_questions`는 비어 있는 게 정상입니다. 지금이라도 켜면 **켠 시점 이후** 질문부터 쌓입니다: `./deploy.sh <walkthrough-project-id/> -var="enable_sensitive_logging=true"`
- 정리하려면: `terraform -chdir=terraform destroy -var project_id=<walkthrough-project-id/>`

자세한 내용은 <walkthrough-editor-open-file filePath="README.md">README.md</walkthrough-editor-open-file> 를 참고하세요.
