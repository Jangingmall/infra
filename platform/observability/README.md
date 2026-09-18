# 관측성 Argo CD 배포 연결

## 무엇이 연결됐나

Git에 저장한 관측성 설정을 Argo CD가 직접 렌더링하고 배포하도록 Stage·Prod Application을 추가했다.
**코드 연결과 로컬 검증 범위다. 실제 EKS 배포·수집·AWS 인증 검증은 아직 하지 않았다.**

```text
infra/main
 ├─ 외부 Helm chart + 환경별 values → Prometheus/Grafana/Alertmanager, Loki, Alloy, DCGM
 ├─ observability-assets chart → 대시보드 ConfigMap, Alloy 설정, Loki 최소권한 Role
 └─ Kustomize → StorageClass, Monitor, 경보 규칙, 수집용 NetworkPolicy, 선택 OTel Collector
             ↓
   해당 환경의 Argo CD Application에서 diff 확인 → 수동 Sync → 상태 확인
```

Stage·Prod는 서로 다른 EKS와 Argo CD를 사용한다. 한 클러스터에 두 환경의 Application을 함께 등록하지 않는다.
모든 Git source는 `main`을 추적하므로 **이번 코드가 main에 합쳐진 뒤** 등록한다.
새 Application의 `automated.enabled: false`는 처음에 자동 배포하지 않는다는 뜻이다. 등록하면 비교는 하지만 Sync를 눌러야 반영한다.
`selfHeal: true`도 automated가 꺼져 있을 동안에는 자동 복구를 시작하지 않는다.
설정 준비와 Stage 검증 후 필요한 Application만 Git에서 `enabled: true`로 바꿀 수 있다. 자동 prune은 계속 꺼둔다.

Backend 외부 접속은 별도 [backend-networking Application](../networking/README.md)을 준비한다. targets의 Backend 메트릭 정책만 적용하면 8080 수신이 격리되므로 ALB 예외를 함께 점검한다.

## 환경당 Application 10개

이름 앞에는 `stage-observability-` 또는 `prod-observability-`가 붙는다.

| 접미사 | 배포 대상 | 처음 Sync할 조건 |
|---|---|---|
| storage | 암호화 EBS용 gp3-monitoring StorageClass | EBS CSI와 IAM 준비 |
| metrics | Prometheus Operator·Prometheus·Grafana·Alertmanager·노드/상태 Exporter, 대시보드 | monitoring namespace, System large 노드, 관리자 Secret, EBS 준비 |
| targets | Backend/CNPG/Argo/로그 Monitor, 공통 경보 규칙, 관련 ingress 정책 | metrics CRD와 수집 대상 Controller 준비 |
| loki | Loki·gateway·rules sidecar, ConfigMap 전용 Role, 버킷 ConfigMap | 실제 환경 버킷과 loki-sa IRSA 준비 |
| alloy-pods | 노드별 Pod 로그 수집기와 설정 | Loki 준비, containerd 로그 경로 및 읽기 권한 확인 |
| alloy-events | Kubernetes Events 수집기 1개와 설정 | Loki 및 Kubernetes API 접근 준비 |
| gpu | DCGM Exporter와 수집 정책 | metrics CRD, NVIDIA 드라이버·runtime 준비 |
| tempo | 단일 Tempo·WAL PVC·IRSA SA·Monitor·NetworkPolicy | metrics CRD, EBS, 실제 S3/IRSA 및 S3·STS egress 인계 후 수동 Sync |
| ai-metrics | AI API PodMonitor와 TCP 8000 수집 정책 | AI팀의 양쪽 API `/metrics` 제공 확인 후 선택 Sync |
| traces | OTel Collector·설정·수집기 정책·Monitor | Tempo Ready 확인 후 수동 Sync; 주소 ConfigMap은 Git에서 생성 |

GPU 노드 수가 0이면 DCGM DaemonSet의 실행 Pod도 0이다. 이것을 GPU 장치 수집 성공으로 판단하지 않는다.
AI API 메트릭과 GPU 장치 메트릭은 별개다. DCGM만으로 AI 요청 성공률·응답 지연을 알 수 없다.
`traces`는 Tempo를 설치하지 않는다. 앱의 Span 전송 코드도 추가하지 않는다.
앱 egress 전체 정책 적용 시 `traces/application-egress` 허용 묶음을 해당 앱 정책과 함께 검토한다. Collector만 켰다고 앱에 새 egress 격리를 적용하지 않도록 이 묶음은 traces Application에 넣지 않았다.

## 파일을 직접 공급하는 방법

### Grafana 대시보드

`platform/observability/Chart.yaml`은 파일 리소스만 만드는 작은 Helm chart다. 추가 서버나 sidecar를 띄우지 않는다.
기존 Backend/GPU/CNPG/Argo JSON을 `.Files.Get`으로 읽어 ConfigMap 4개를 만든다. JSON 복사본을 따로 관리하지 않는다.
metrics Application의 두 번째 Git source가 이 chart를 렌더링하며, 외부 metrics chart와 **같은 Application**이 소유한다.
Grafana는 ConfigMap을 디렉터리로 마운트하고 30초마다 파일을 다시 읽는다. kubelet의 ConfigMap 갱신 지연은 별도다.
`subPath`를 사용하지 않아 JSON 내용 변경에 Grafana 재시작이 필요 없다. datasource/provider 변경은 기존 checksum에 따라 재시작한다.

외부 Helm chart만 단독 설치하면 팀 대시보드 ConfigMap이 빠진다. 아래 렌더러 또는 Argo CD의 전체 sources를 사용한다.
Git source의 `$values`는 values 파일에 사용하며, 지원 여부가 다른 `fileParameters`로 JSON을 주입하지 않는다.

### Alloy 로그 설정

같은 assets chart가 `logs/pods.alloy` 또는 `logs/events.alloy`와 `collectors/log-buffer.alloy`를 합친다.
Alloy Helm chart는 `configMap.create: false`로 두고 해당 ConfigMap 이름을 참조한다.
기존 config-reloader는 유지하여 파일 변경 시 reload한다. Grafana sidecar 제거와 다른 구성이다.
환경 라벨 `OBS_ENV`와 내부 Loki URL은 Application에 명시한다. Stage 로그가 Prod 라벨로 기록되지 않는지 CI에서 검사한다.

### Loki Secret 조회 권한 제거

Loki chart 7.3.0은 rules sidecar Role에 ConfigMap과 Secret 조회를 함께 넣는다.
첫 번째 source는 공식 chart, 두 번째 source는 **같은 이름의 ConfigMap 전용 Role**을 만든다.
Argo CD는 같은 Application 내 중복 리소스에서 뒤쪽 source를 사용한다. 따라서 적용할 최종 Role에는 Secret 조회가 없다.

이 경우 Argo CD에 **RepeatedResourceWarning이 Loki Role 한 건** 표시될 수 있다. 의도한 source override다.
이 한 건 외 중복은 허용하지 않는다. source 순서를 바꾸면 권한이 넓어질 수 있어 렌더러가 최종 Role을 검사한다.
Application 간 중복 소유는 `FailOnSharedResource=true`로 차단하며, 이 정책은 같은 Application의 source override와 별개다.
로컬 렌더러도 같은 순서로 결합하므로 예전 Ruby 후처리에만 권한 제한을 의존하지 않는다.

## 배포 전에 받을 값

| 값 | 입력/준비 위치 | 담당·주의사항 |
|---|---|---|
| Loki S3 버킷 이름 | runtime/stage.yaml 또는 prod.yaml의 lokiBucket | 인프라 제공. 실제 환경 버킷, 비밀값 아님 |
| Loki IRSA Role ARN | 같은 파일의 serviceAccount.annotations.eks.amazonaws.com/role-arn | loki-sa 신뢰 조건과 환경 버킷 loki/* 권한 확인 |
| Grafana 로그인 정보 | monitoring/grafana-admin Secret의 admin-user, admin-password | 안전한 별도 공급 절차로 준비. Git에 값 저장 금지 |
| Discord IRSA Role ARN | 같은 runtime 파일의 alertmanager.serviceAccount.annotations.eks.amazonaws.com/role-arn | Discord 선택 활성화 전에 준비 |
| Discord webhook | SSM SecureString, 제안 경로 /staging 또는 /prod/monitoring/discord-webhook-url | Git·CI·values에 실제 URL 저장 금지 |
| Tempo S3·IRSA·egress | tempo/runtime/stage.yaml 또는 prod.yaml | [Tempo 배포 기반](tempo/README.md)의 준비 항목을 모두 충족한 뒤 Sync |
| Tempo 주소 | Kustomize가 생성하는 traces-runtime-<hash>의 TEMPO_OTLP_ENDPOINT | tempo.monitoring.svc.cluster.local:4317, Stage·Prod 각각의 내부 Service |

runtime 파일은 기본 `{}`다. 가짜 버킷·ARN·Webhook은 넣지 않았다.
Loki 버킷을 입력하면 assets chart가 `logs-runtime` ConfigMap을 만든다. ARN은 외부 chart가 만드는 `loki-sa` annotation에 반영한다.
SSM 파라미터 등록, IAM Role/정책/버킷 생성은 인프라 담당이다. Terraform과 Backend·AI 저장소는 수정하지 않았다.

예시 구조의 꺾쇠 부분은 실제 인계값으로 바꾼다. 이것을 그대로 배포하지 않는다.

```yaml
lokiBucket: <해당 환경의 실제 버킷 이름>
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: <Loki 실제 IRSA Role ARN>
alertmanager:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: <Discord 실제 IRSA Role ARN>
```

## Discord를 켜는 방법

기본 metrics Application은 경보를 Alertmanager 안에서 관리하지만 외부 전송은 null 수신자로 꺼둔다.
SSM·CSI Driver·실제 IRSA 준비 후, **해당 환경** `argocd/applications/stage/kustomization.yaml`에 추가한다.

```yaml
components:
- ../../components/observability-discord/stage
```

Prod는 두 경로의 stage를 prod로 바꾼다. component가 다음을 함께 반영한다.

1. 기존 metrics Helm source에 Discord 공통·환경별 values를 추가한다. runtime override는 마지막에 유지한다.
2. 같은 metrics Application의 assets source에서 `monitoring-discord` SecretProviderClass를 생성한다.
3. 기존 Alertmanager가 CSI 파일의 webhook을 읽는다. Kubernetes Secret 동기화는 추가하지 않는다.

별도 metrics release/Application을 새로 설치하지 않는다. 동일 Alertmanager를 둘이 소유하면 안 된다.
선택 component를 추가한 후에는 raw `observability.yaml`만 apply하지 말고, Kustomize 결과에서 관측성 Application을 등록한다.

```bash
# 선택한 환경의 context/Argo CD에 로그인했고 선행조건을 확인한 운영자만 실행
kubectl --context '<Stage context>' apply -f argocd/applications/stage/observability-project.yaml
kubectl kustomize argocd/applications/stage | \
  kubectl --context '<Stage context>' apply -l app.kubernetes.io/part-of=observability -f -
```

Argo CD의 metrics diff에서 SPC, CSI 볼륨, 파일 경로, SA ARN, 환경 라우트를 함께 확인한 후 Sync한다.
SSM 등록이나 파일 자동 갱신만으로 Alertmanager가 즉시 새 URL을 읽는다고 가정하지 않는다. URL 교체 시 CSI 갱신 및 Alertmanager reload/restart 후 실제 수신을 검증한다.

## 최초 설치 순서

별도 Application 사이의 readiness를 `sync-wave`만으로 보장하지 않는다. 아래 순서대로 완료 상태를 확인한다.
기존 `workloads` Application이 monitoring namespace를 소유한다. 관측성이 Namespace를 중복 생성/관리하지 않는다.
workloads 전체가 아직 배포 불가능하면 담당자와 Namespace만 선행 준비하는 절차를 확정한다. Namespace 생성만 위해 준비 안 된 AI/DB까지 동기화하지 않는다.

1. 올바른 Stage context, main merge, Argo CD Git 읽기 권한, System medium 1 + large 1, EBS CSI, monitoring namespace를 확인한다.
2. Grafana Secret을 준비하고 위 명령으로 관측성 project와 Application을 등록한다. 등록만으로 자동 배포되지 않는다.
3. `stage-observability-storage`를 Sync한다. gp3-monitoring과 EBS CSI 상태를 확인한다.
4. `stage-observability-metrics`를 Sync한다. CRD Established, Operator Ready, PVC Bound, Prometheus/Grafana/Alertmanager 상태를 확인한다.
5. CNPG/Argo/Rollouts 대상 Controller 준비 후 `stage-observability-targets`를 Sync한다. 초기 수집 대상이 없는 경보는 실패 원인을 확인한다.
6. 실제 버킷·IRSA를 넣고 `stage-observability-loki`를 Sync한다. gateway Ready와 S3 접근을 확인한다.
7. `stage-observability-alloy-pods`, `stage-observability-alloy-events`를 Sync한다. 로그와 Events가 조회되는지 확인한다.
8. NVIDIA 환경 준비 후 `stage-observability-gpu`를 Sync한다. L40S·T4 메트릭을 확인한다.
9. 실제 S3·IRSA·네트워크를 확인한 뒤 `tempo`를 Sync한다. PVC Bound와 Tempo Ready/저장·조회 검증을 마친다. `ai-metrics`는 AI API 준비 후, `traces`는 Tempo Ready 확인 후 각각 Sync한다. 준비 전에는 OutOfSync/Missing 상태로 남아 있어도 배포하지 않는다.
10. Discord는 앞의 선택 component로 켠 뒤 시험 경보 발생·복구와 잘못된 환경 경보 차단을 확인한다.
11. Stage에서 통과한 설정을 Prod의 실제 ARN·버킷·Secret과 대조하여 같은 순서로 진행한다.

Sync 예시:

```bash
argocd app diff stage-observability-metrics
argocd app sync stage-observability-metrics
argocd app wait stage-observability-metrics --sync --health --timeout 600
```

wait 실패 시 원인을 확인하고 다음 단계로 넘어가지 않는다. Git diff만으로 Pod Ready/수집 성공을 판단하지 않는다.
기존 수동 Helm 설치가 있다면 인계 diff와 동일 release 이름을 확인한다. Argo CD 인계 후 수동 helm upgrade로 같은 리소스를 계속 관리하지 않는다.
관측성 Application에는 cascading deletion finalizer를 넣지 않았고 자동 prune도 껐다. 삭제는 별도 검토 작업이다.
StorageClass는 Prune/Delete 확인 보호, EBS reclaimPolicy는 Retain이다. Retain은 백업이 아니며 종료 시 잔여 EBS 정리는 필요하다.

## 로컬 검증

```bash
ruby scripts/render-observability.rb stage /tmp/observability-stage
ruby scripts/render-observability.rb prod /tmp/observability-prod
ruby scripts/render-observability.rb stage /tmp/observability-discord --discord metrics
bash scripts/validate-observability-gitops.sh
bash scripts/validate-k8s.sh
```

렌더러는 Application의 실제 chart 버전·releaseName·valuesFiles·valuesObject·Git path를 읽는다.
Argo CD용 설치 플러그인이 아니라 개발자/CI의 검증 도구다. Argo CD는 표준 Helm/Kustomize 기능만 사용한다.
외부 차트 다운로드와 promtool/amtool 실행용 Docker가 필요하다. AWS 자격증명과 클러스터 접근은 필요 없다.
출력 YAML에는 Secret 리소스 형식의 Alertmanager 설정이 포함될 수 있으므로 실제 비밀값을 검증 입력으로 넣지 않는다.

검사 범위:

- Stage·Prod의 chart/Kustomize 렌더링, AppProject 종류·namespace·저장소 허용 범위.
- workloads와 관측성 Application 사이 중복 소유 및 Loki Role 이외 source 중복 차단.
- 대시보드 파일 마운트, 수집 selector/port, 환경 라벨, 보존 기간, System/GPU 배치, Loki Secret 권한 제거.
- Discord 선택 component가 기존 metrics source를 확장하고 CSI/환경 라우팅을 유지하는지 확인.
- 기존 공통 경보와 알림 규칙 검사 유지.

실제 EKS에서 남은 검증: Argo CD reconcile/health, CRD webhook, IRSA·SSM·S3, CSI/PVC, NetworkPolicy 허용·차단, 실제 Backend/GPU 수집, 경보 발생·수신·복구, 장애 및 데이터 보존.
Tempo 배포 기반은 추가했지만 실제 AWS 저장 검증, CloudWatch·앱 계측·통합 추적은 아직 남아 있다.

근거: [Argo CD multiple sources](https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/), [Helm integration](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/), [Sync options](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/).

### 기존 관측성 연결 작업의 로컬 확인 결과 (Tempo 추가 전)

- `bash scripts/validate-k8s.sh` 전체 검사 통과. Stage·Prod별 관측성 Application 9개의 실제 소스를 렌더링했다.
- Discord 선택 구성, 공통 경보 20개 및 발생/복구·환경 라우팅 검사를 통과했다.
- Grafana 13.2.2 HTTP API에서 Backend/GPU/CNPG/Argo 대시보드 4개와 데이터소스 3개를 확인했다. JSON 제목 변경이 같은 컨테이너에서 재시작 없이 반영됐다.
- Argo CD 소스에서 만든 Pod/Events 설정을 Alloy v1.19.2의 실제 `validate` 명령으로 검사했다.
- 임시 입력의 대시보드 누락과 Loki Secret 조회 권한 추가를 각각 실패로 검출했다. CLI 도움말·잘못된 인자, Bash/Ruby 문법도 확인했다.
- 로컬 Grafana QA의 검색용 쓰기 볼륨 누락은 테스트 환경에서 보완했다. 원래 Helm 산출물에는 해당 emptyDir가 있으므로 배포 코드는 변경하지 않았다.
- 기존 HPA 4 + Preview 1의 App 용량 경고는 유지된다. 이 작업은 Backend 자원/HPA를 변경하지 않았다.
