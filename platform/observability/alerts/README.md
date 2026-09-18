# 경보 규칙 · Discord · Parameter Store 연결

## 현재 어디까지 했는가

**실제 Parameter Store 등록 전까지의 코드다.** SSM 파라미터/IAM Role 생성, 실제 Discord Webhook 등록·전송 및 EKS 적용은 수행하지 않았다. 로컬 모의 수신 서버에서는 발생·복구 메시지 전송을 검증했다. 기존 metrics 기본 values는 계속 `null` 수신자를 사용한다. 아래 Discord values를 명시적으로 추가한 경우에만 CSI 마운트와 외부 전송 경로가 열린다.

```text
메트릭 → PrometheusRule → Alertmanager → Discord
                              ↑
Parameter Store SecureString → AWS CSI 파일 마운트
       (환경별 IRSA로 조회)       webhook_url_file
```

Alertmanager는 기존 1개를 사용하고 리소스 요청량도 유지한다. 별도 중계 Pod나 Secret 복제용 Pod는 없다. Spring configtree는 사용하지 않는다. Alertmanager가 파일을 직접 읽는다.

## 기준과 범위

[노션 3.5 알림·런북 설계](https://app.notion.com/p/1130842d874f82ec8acf813ebbfe5e75)를 기준으로 했다. 문서의 핵심 10종 중 실제 메트릭으로 작성 가능한 **7종**을 구현했다. 앞선 대화에서 요청한 공통/GPU/DB 연결 경보 **7종**을 추가했다. Severity·namespace·수집 job에 따라 YAML 선언은 **총 20개, 경보 종류는 14종**이다. 핵심 10종 전체가 구현됐다는 의미는 아니다.

기존 chart 기본 경보는 평가와 UI 표시를 유지하지만, `notify=discord`가 없는 경보는 이 Discord 경로에서 전송하지 않는다. 핵심 경보와 기본 경보의 중복 전송을 막고 검토한 범위부터 운영하기 위함이다. 기본 경보를 외부 전송하려면 해당 조건의 기존 규칙과 중복 여부를 검토한다.

### 구현한 핵심 7종

| 경보 | 초기 조건 | 심각도 / 담당 |
| --- | --- | --- |
| BackendAvailableReplicasZero | Rollout 보고 가용 Pod 0, 2분 | Critical / Cloud Native |
| BackendHTTP5xxRateHigh | revision별 5분 요청 100건 이상 AND 5xx 2%/5% 이상, 5분 | Warning/Critical / Backend |
| BackendPodRestartHigh | 같은 컨테이너 10분간 재시작 3회 이상, 2분 | Warning / Cloud Native |
| ArgoRolloutDegradedOrStalled | 고정 exporter의 Error/Timeout/InvalidSpec/Abort, 2분 | Critical / Cloud Native |
| CNPGPrimaryUnavailable | 관측된 DB 중 응답 가능한 Primary 없음, 1분 | Critical / DB·DR |
| CNPGReplicationLagHigh | 복제 지연 30초 이상, 5분 | Warning / DB·DR |
| PVCUsageHigh | database/monitoring PVC 80%/90% 이상, 5분 | Warning/Critical / namespace별 DB·DR 또는 Cloud Native |

- 5xx는 Health/Metrics Endpoint를 제외하며 4xx를 서버 오류로 합산하지 않는다. revision별이라 Preview 오류도 잡지만 운영 사용자 영향과 동일하다고 단정하지 않는다.
- 100건/5분 Gate는 이번 구현의 초기 제안이다. 트래픽이 작으면 사용자 장애가 있어도 이 비율 경보는 발생하지 않을 수 있다. Pod 가용성 경보 및 실제 요청 시험과 함께 판단한다.
- 가용 Pod 수는 Rollout의 보고값이다. Preview가 살아 있다는 이유로 Active Service까지 정상이라고 보장할 수 없으므로 Active Service/ALB 검증은 별도다.
- Rollouts 1.10 exporter의 실제 phase 이름은 `Degraded` 대신 `Error`, `Timeout`, `InvalidSpec`, `Abort`다. 정상 `Paused`나 단순 `Progressing`은 경보로 만들지 않는다. 계획된 Abort는 Silence로 처리한다.
- CNPG 지표가 전부 사라졌을 때 DB 장애를 추정하지 않는다. 별도의 수집 대상 누락 경보를 확인한다. 이 지표로 rw Service 연결 성공까지 보장하지 않는다.
- 중복 수집되는 kubelet/Controller gauge는 `max`로 처리한다.

### 요청에 따라 추가한 7종

| 경보 | 초기 조건 | 첫 확인 / 담당 |
| --- | --- | --- |
| CNPGConnectionsHigh | 실제 연결 상한 대비 80% 이상, 5분 | Hikari·장기 쿼리·연결 해제 / DB·DR + Backend |
| NodeNotReady | Ready=false, 5분 | Node·네트워크·영향 Pod / Cloud Native → Infra |
| WorkloadPodPending | app/database/ai/monitoring Pod Pending, 15분 | requests·taint·selector·PVC·GPU 준비 / Cloud Native |
| MonitoringTargetDown | 발견된 Endpoint scrape 실패, 5분 | Monitor·Pod·포트·NetworkPolicy / Cloud Native |
| MonitoringTargetMissing | backend/cnpg/argo-rollouts job 자체 없음, 10분 | 해당 수집 묶음이 적용됐는지 / Cloud Native |
| GPUDeviceError | 0이 아닌 유효한 XID 코드, 1분 | AI 영향·NVIDIA 드라이버 로그 / Cloud Native → Infra·AI |
| GPUMemoryHigh | GPU 메모리 95% 이상, 10분 | OOM·모델 크기·상주 메모리 / AI + Cloud Native |

이 추가 7종은 노션의 핵심 10종에 대한 변경 합의로 취급하지 않는다. 요청에 따른 초기 확장이다. 특히 GPU 메모리는 모델이 미리 예약해서 항상 높을 수 있고, Pending은 정상 GPU 기동 시간보다 길게 조정해야 한다. Stage 기준선 확인 후 불필요한 경보는 조정한다.

GPU 연산 사용률 100%는 경보 조건이 아니다. GPU 노드가 0개일 때 시계열이 없다는 이유로 GPU 장애를 발생시키지 않는다. XID는 누적 오류 횟수가 아니라 마지막 코드이며, 장애를 해결해도 드라이버 상태가 갱신되기 전까지 남을 수 있다. 코드 변경 횟수로 바꾸어 신규 오류를 놓치는 방식은 사용하지 않았다.

### 아직 구현하지 않은 핵심 3종

| 경보 | 필요한 선행조건 |
| --- | --- |
| ALBHealthyHostCountZero | CloudWatch 데이터소스·AWS 조회 권한·실제 ALB/Target Group ID. 문서대로 Grafana Alerting에서 평가 |
| BackendP95LatencyHigh | 실제 histogram과 일반 API/AI Endpoint 분리 기준. 평균값으로 p95를 대신하지 않음 |
| AIInferenceErrorRateHigh | AI가 제공하는 실제 요청/오류 metric 이름과 라벨 계약 |

이 세 가지를 빈 데이터에 정상값을 넣는 형식으로 만들지 않았다. 기존 GPU/AI 인프라 경보는 AI 추론 오류율 경보를 대신하지 않는다.

## 파일과 적용 경로

- `rules/`: 공통 PrometheusRule. 두 환경의 Prometheus `externalLabels.environment`가 Alertmanager에 stage/prod를 전달한다.
- `discord/values.yaml`: 공통 Alertmanager 수신자, 메시지, 억제 규칙, 전용 SA, CSI 파일 마운트.
- `discord/stage/values.yaml`, `discord/prod/values.yaml`: 자신의 environment만 허용하는 라우팅.
- `discord/{stage,prod}/secret-provider.yaml`: 환경별 SSM 경로. 실제 값은 포함하지 않는다.
- `tests/rules.test.yaml`: Pending/Firing/Recovery, 적은 트래픽, Manual Pause, CNPG 역할, 중복 kubelet, GPU 0개 등의 회귀 검증.
- `scripts/validate-alerting.{sh,rb}`: Helm 출력 대조와 promtool/amtool 검사. 기존 K8s CI에 연결했다.

PrometheusRule 적용은 SSM 없이도 가능하다. 하지만 Backend·CNPG·Argo 수집 묶음이 없으면 Missing 경보가 발생하므로 관련 Monitor를 먼저 준비한다. 현재 두 묶음 모두 Argo Application 자동 적용 경로에는 연결하지 않았다.

```sh
# 렌더링만 한다. AWS/EKS에 적용하지 않는다.
kubectl kustomize platform/observability/alerts/rules
kubectl kustomize platform/observability/alerts/discord/stage
kubectl kustomize platform/observability/alerts/discord/prod
bash scripts/validate-alerting.sh
```

## 인프라 담당자에게 요청할 값

| 항목 | Stage | Prod |
| --- | --- | --- |
| 제안 SSM 경로 | `/staging/monitoring/discord-webhook-url` | `/prod/monitoring/discord-webhook-url` |
| 타입 / 값 | SecureString / Stage 채널 Webhook | SecureString / Prod 채널 Webhook |
| Kubernetes SA | `monitoring:alertmanager-sa` | `monitoring:alertmanager-sa` |
| IRSA 신뢰 subject | `system:serviceaccount:monitoring:alertmanager-sa` | 동일 subject, 해당 환경 EKS OIDC |
| IRSA audience | `sts.amazonaws.com` | `sts.amazonaws.com` |
| 반환받을 정보 | 실제 Role ARN, 확정 파라미터 경로, 사용 KMS 키 | 동일 |

- 최소 IAM은 해당 파라미터 ARN 한 개의 `ssm:GetParameters`를 기준으로 한다. 고객 관리 KMS 키를 사용하면 해당 키의 `kms:Decrypt`와 키 정책 허용도 필요하다. 최종 IAM 구현은 인프라 담당 범위다.
- `GetParametersByPath`나 SSM 전체 경로 권한, 장기 AWS Access Key, `pods.eks.amazonaws.com` 신뢰는 요청하지 않는다.
- Webhook은 UI/SSM에서 입력한다. 실제 URL을 PR·로그·이 문서에 적지 않는다.
- Alertmanager의 DNS·Discord HTTPS 443 발신과 CSI Provider의 STS/SSM 접근이 필요하다. 전체 egress 정책 및 SG/VPC Endpoint는 인프라와 확인한다. 이번 작업에서 임의 IP나 광범위 egress 허용을 추가하지 않았다.

기존 CSI 플랫폼은 `sts.amazonaws.com` TokenRequest를 구성한다. SA의 일반 API 토큰 자동 마운트를 꺼도 이 경로는 별도다. 실제 EKS의 IRSA 토큰·파일 권한 검증은 남아 있다.

## Parameter Store 준비 후 연결하는 순서

1. 인프라가 환경별 파라미터와 IRSA를 만들고 실제 ARN·경로를 전달한다.
2. 경로가 제안과 다르면 해당 `secret-provider.yaml`과 IAM Resource를 함께 맞춘다.
3. 환경별 Helm override에 실제 값을 추가한다.

```yaml
alertmanager:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: <인프라가 제공한 해당 환경의 실제 Role ARN>
```

4. GitOps에서는 [Discord 선택 component](../README.md)를 해당 환경 Kustomization에 추가한다. 같은 metrics Application이 아래 두 values·runtime ARN override·SecretProviderClass·대시보드 assets를 함께 공급한다. 이미 Argo CD가 관리하면 별도 Helm release로 설치하지 않는다.

```sh
-f platform/observability/alerts/discord/values.yaml \
-f platform/observability/alerts/discord/stage/values.yaml
# Prod는 마지막 경로만 discord/prod/values.yaml
```

5. PrometheusRule과 관련 Monitor가 선택되는지 확인한다. Alertmanager Pod가 Ready이고 마운트가 성공하는지 확인한다. 파일 내용을 터미널에 출력할 필요는 없다.
6. Stage에서 시험 경보 → 실제 Discord 수신 → 억제/Silence → 복구 메시지를 검증한다. Prod는 동일 코드와 별도 Webhook으로 연결한다.

실제 ARN이나 SSM이 없는데 Discord values부터 배포하면 Alertmanager가 FailedMount로 멈출 수 있다. 따라서 기본 values와 분리했다. 되돌릴 때는 Discord 추가 values를 제거한 기존 Helm 입력으로 복구한다. Rule은 UI 확인용으로 남길 수 있다.

**Webhook 교체:** 현재 공통 CSI의 자동 rotation은 꺼져 있다. Parameter Store 값을 바꿨다고 마운트 파일이 즉시 바뀌지 않는다. 새 값 등록 후 관리되는 Alertmanager Pod 재생성/재마운트 절차를 Stage에서 검증하고 적용해야 한다. 공통 rotation을 이 기능 때문에 임의로 켜지 않았다.

## 메시지·소음 제어

- `[FIRING/RESOLVED][STAGE/PROD][WARNING/CRITICAL]`과 담당, 대상, 조건·현재 값, 시작 시각, revision, 화면, 런북을 전달한다.
- 같은 environment/component/alertname/severity를 묶는다. 최초 30초 대기, 갱신 5분, Warning 2시간/Critical 30분 반복이 초기값이다.
- Critical은 동일 alertname과 동일 namespace/PVC/pod/revision/장치의 Warning만 억제한다. 다른 revision이나 다른 PVC의 경보까지 억제하지 않는다.
- Slack·전체 역할 mention·자동 rollback은 추가하지 않았다.
- 본문은 최대 3개 경보와 길이를 제한한 요약을 표시한다. 나머지는 Alertmanager에서 확인한다.
- Grafana 외부 URL은 아직 확정되지 않아 `dashboard_url`에 상대 경로를 넣었다. 실제 클릭 가능한 링크는 운영 URL 인계 후 완성한다. 런북 링크는 현재 노션 문서이며 접근 권한이 필요하다. 추가 7종의 1차 대응은 위 표와 아래 절차를 함께 사용한다.
- 외부 네트워크가 끊기거나 Alertmanager 자신이 내려가면 이 경로만으로 운영자에게 알릴 수 없다. 독립 외부 감시는 이번 범위에 포함하지 않는다.

## 추가 경보의 1차 대응

1. **영향 확인:** Backend/AI 요청이 실패하는지, 특정 Pod/revision만 문제인지 확인한다. 수집 실패만으로 앱 장애를 단정하지 않는다.
2. **최근 변경 확인:** 이미지·모델·requests/limits·IAM·NetworkPolicy 변경 시각과 경보 시작을 비교한다.
3. **안전한 조치 선택:** GPU 기동 중 Pending인지 확인하고, 메모리 부족은 모델 상주량/동시성을 AI팀과 확인한다. DB 연결은 풀/장기 쿼리를 Backend·DB 담당과 확인한다. 데이터·WAL을 임의 삭제하거나 Primary를 강제 교체하지 않는다.
4. **협업 전달:** 위 표의 담당자에게 namespace/pod/node, 증상, 시작 시각, 최근 revision, Event/로그의 비밀값을 제외한 근거를 전달한다.
5. **복구 확인:** 해당 메트릭의 회복, 실제 요청 성공, RESOLVED를 함께 확인한다. 트래픽이 사라져 비율 경보가 해제된 경우를 정상 복구로 착각하지 않는다.
6. **기록:** 원인·조치·복구 시각과 조정할 임계값을 남긴다. EKS 명령은 Stage에서 검증한 뒤 런북에 추가한다.

## 검증과 남은 확인

로컬 검증은 실제 AWS/Discord 접근 없이 수행한다.

- 고정 차트 91.4.1 → Alertmanager 0.34.0 / Prometheus 3.14.0 기준.
- `promtool check rules`, `promtool test rules`: 20개 선언과 12개 시나리오 검증.
- `amtool check-config`: 환경별 실제 Helm 출력, 메시지 template 검사.
- 내부 전용 Docker 네트워크에서 실제 Alertmanager 두 개와 mock HTTP 수신 서버 실행. 실제 Discord API 형식으로 시험 메시지를 수신하고 Firing/Resolved, 환경 누락·교차 환경 차단, 동일 revision 억제 및 다른 revision 유지 확인.
- 실제 Discord Webhook, AWS IRSA/CSI, SecureString 복호화, SG/NetworkPolicy, 실제 메트릭 의미·라벨, Grafana 링크, Silence 운영 절차, Production 임계값은 EKS/협업 확인이 남아 있다.

근거: [고정 Alertmanager 설정](https://github.com/prometheus/alertmanager/blob/v0.34.0/docs/configuration.md), [고정 Rollouts phase 계산](https://github.com/argoproj/argo-rollouts/blob/v1.10.0/controller/metrics/rollouts.go), [AWS CSI IRSA 안내](https://docs.aws.amazon.com/secretsmanager/latest/userguide/integrating_ascp_irsa.html).
