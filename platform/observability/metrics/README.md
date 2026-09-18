# 공통 메트릭 기반

## 목적과 범위

[관측성 설계](https://app.notion.com/p/c760842d874f83758b7b81f9766b276e)의 Metrics 기본안을 구현한다.
고정 차트는 `kube-prometheus-stack 91.4.1`, release 이름은 `metrics`, namespace는 `monitoring`이다.
`values.yaml`과 환경별 `stage.yaml` 또는 `prod.yaml`을 함께 사용한다.

**Argo CD Application 연결을 제공하며 최초 자동 동기화는 꺼뒀다.** System 노드 전체 용량과 아래 선행조건을 확인한 뒤 [관측성 배포 순서](../README.md)에 따라 수동 Sync한다.
이번 설정은 공통 메트릭 기반이며 관측성 전체 완료를 뜻하지 않는다.

## 무엇을 볼 수 있도록 구성했나

| 구성 | 관측 내용 / 역할 | 이유 |
|---|---|---|
| Prometheus | kubelet/cAdvisor의 컨테이너 CPU·메모리, API server 및 수집기 자체 메트릭 저장 | 자원 부족과 수집 장애 확인 |
| kube-state-metrics | Node/Pod 상태, Pending, 재시작, Deployment replica, HPA 등 Kubernetes 오브젝트 상태 | 원하는 상태와 실제 상태 차이 확인 |
| node-exporter | Linux 노드의 CPU·메모리·디스크·네트워크 | 노드 자원 부족 원인 분석 |
| Grafana | 차트 기본 Kubernetes 대시보드 및 Prometheus/Alertmanager 데이터소스 | 수집한 수치를 화면으로 확인 |
| Alertmanager | 기본 경보 및 별도 팀 경보를 그룹화 | Discord 설정 준비; 실제 SSM/IRSA·외부 수신 검증은 미완료 |
| Prometheus Operator | Prometheus/Alertmanager 및 Monitor/Rule 관리 | 선언한 수집 설정을 실제 구성으로 변환 |

차트 기본 대시보드는 설계의 팀 전용 8개 대시보드를 완성한 것이 아니다.
표의 항목은 수집 설정의 범위이며 실제 Target UP/데이터 존재는 EKS에서 확인한다.
EKS 관리형 etcd·scheduler·controller-manager 수집과 관련 규칙은 비활성화했다.
kube-proxy는 metrics bind address 확인 후 수집 여부를 정한다.

## 환경과 저장소

| 항목 | Stage | Prod |
|---|---|---|
| 수집/규칙 평가 주기 | 30초 | 30초 |
| Metrics 보존 | 7일 | 15일 |
| Prometheus PVC 초기 제안 | 20Gi | 40Gi |
| TSDB size guard | 16GB | 32GB |
| Grafana PVC | 2Gi | 2Gi |
| Alertmanager PVC | 2Gi | 2Gi |

시간/크기 제한 중 먼저 도달하는 조건으로 데이터가 지워질 수 있다. 15일 보존이 무조건 보장되는 것은 아니다.
WAL·head block·compaction 때문에 size guard도 파일시스템 사용량의 절대 상한은 아니다.
PVC는 실제 active series와 samples/sec, 일일 증가량을 보고 조정한다.
`gp3-monitoring`은 EBS CSI, 암호화 gp3, WaitForFirstConsumer, Retain을 사용한다.
클러스터 종료 시 PVC 삭제만으로 EBS가 삭제되지 않으므로 인프라 종료 절차에서 잔여 EBS를 확인한다.
Grafana는 단일 RWO PVC이므로 Recreate 방식이다. 업데이트 중 조회 중단이 있을 수 있다.

## 배치와 자원

중앙 구성과 인증서 초기화 Job은 `workload-type=system`으로 배치한다.
node-exporter는 Linux 노드에서 실행하고 DB/GPU의 NoSchedule taint도 허용한다.
GPU 장치 메트릭은 별도 [DCGM Exporter 구성](../gpu/README.md)으로 수집하도록 작성했다.
System은 t3.medium 1대 + t3.large 1대다. Prometheus는 large에 지정하고 Loki는 medium 우선 및 저장 Pod 간 soft anti-affinity를 적용한다. Tempo는 미구현이며 분산·HA를 보장하지 않는다.

System 노드 2대 기준 공통 메트릭 요청량은 **880m / 2404Mi**다.
Prometheus/Alertmanager에 Operator가 생성하는 reloader 2개(20m/100Mi)를 포함한 계산이며 실제 Pod 생성 후 재확인한다.
인증서 Job은 각각 50m/64Mi를 일시적으로 추가한다. limits·init container·업데이트 겹침은 별도로 검토한다.
App/DB/GPU 노드에는 node-exporter가 노드당 30m/64Mi 추가된다.
Dashboard 제외 기존 플랫폼·제안 Controller 요청량 2016Mi와 합하면 4420Mi이지만 **일부 EKS 애드온과 Logs/Traces는 빠져 있다.**
메트릭만의 부분합을 전체 스택 수용 가능 근거로 사용하지 않는다. [전체 용량 검토](../capacity.md)를 따른다.

## 인증과 수집 대상 경계

- Prometheus/Grafana/Alertmanager는 ClusterIP만 사용하고 Ingress를 생성하지 않는다.
- 내부 ClusterIP는 인증이나 NetworkPolicy를 대신하지 않는다. 실제 접근 정책은 아래 배포 선행조건에 포함한다.
- Grafana는 `monitoring/grafana-admin` Secret의 `admin-user`, `admin-password`를 참조한다. 암호를 Git/values에 넣지 않는다. Secret 제공 절차를 담당자와 확정한다. 이 Secret은 AI CSI 비밀번호 복제와 별개인 Grafana 인증정보다.
- 익명 접근과 자가 가입은 비활성화한다. SSO/CloudWatch IRSA는 아직 연결하지 않는다.
- Prometheus는 `monitoring` namespace의 `release=metrics` Monitor/Rule을 선택한다.
- Backend/AI PodMonitor는 monitoring에 작성하고 `spec.namespaceSelector`로 대상 앱 namespace를 지정했다. AI API 수집은 실제 /metrics 제공 확인 후 선택 적용한다. 수집용 NetworkPolicy도 함께 적용해야 한다.
- 기본 Alertmanager의 수신자는 null이다. 별도 Discord values와 환경별 SSM/IRSA를 연결해야 외부 전송 경로가 활성화된다. 실제 외부 수신은 미검증이다.

## 배포 전 선행조건

- [ ] 전체 System 용량, EKS addon 자원/replica, AZ와 장애 시 유지 범위 확정
- [ ] monitoring namespace, EBS CSI Driver·IAM 준비 및 StorageClass 적용
- [ ] Grafana 관리자 Secret 준비와 운영자 접근 방법 확정
- [ ] EKS control plane → Operator webhook 10250 통신 확인
- [ ] Prometheus → API server 443 / kubelet 10250 / node-exporter 9100 통신 확인
- [ ] monitoring 내부 Service 통신 및 SG/NetworkPolicy 설계 반영; hostNetwork node-exporter는 CNI 정책 적용 범위도 확인
- [ ] Prometheus Operator CRD 설치·업그레이드 절차 확정
- [x] GitOps AppProject 권한·Application·설치 순서 코드 연결 (실제 reconcile은 EKS 검증 대기)
- [ ] Alertmanager 수신 채널/임계값/Runbook은 별도 알림 설계와 대조

서버 접근 없이 설정 검증: `bash scripts/validate-observability.sh`.
전체 검증: `bash scripts/validate-k8s.sh`. CI에는 렌더링 검증만 추가하며 AWS/EKS에 배포하지 않는다.
차트 버전은 Argo CD Application에 고정하고 검증 스크립트가 읽는다. 버전 변경 시 차트 기본값·리소스·수집 지표를 다시 확인한다.

## EKS 검증 순서

1. 올바른 환경 values로 렌더링하고 PVC/Node 배치와 보존 기간을 확인한다.
2. CRD/Controller 준비 후 Prometheus/Alertmanager CR의 Ready와 PVC Bound를 확인한다.
3. 운영자 port-forward로 Grafana 로그인 및 Prometheus Targets를 확인한다.
4. kubelet, node-exporter, kube-state-metrics, API server의 Target UP을 확인한다.
5. 실제 Pod의 CPU·메모리·Pending/재시작 값을 Kubernetes 조회 결과와 비교한다.
6. Grafana/Prometheus 재시작 후 저장 데이터와 경보 상태를 확인한다.
7. 정상 사용자 트래픽과 쿼리를 가하며 메모리·OOM·TSDB 증가·T3 CPU credits를 측정한다.
8. Backend/AI 전용 수집, Logs·Traces, 알림 채널은 각 연결 작업에서 추가 검증한다.

## 남은 구현 단위

1. 공통 기반의 Logs: [Alloy → Loki 설정](../logs/README.md) 작성·로컬 검증 완료. GitOps 연결 제공. 실제 S3/IRSA 인계·EKS 검증은 대기.
2. 공통 기반의 Traces: 지원되는 Tempo 배포 경로, OTel Collector, S3/IRSA, Grafana 상호 조회.
3. Backend/CNPG/Argo 전용 Monitor·대시보드·알림과 NetworkPolicy.
4. GPU/DCGM·AI 전용 Monitor·대시보드·알림과 NetworkPolicy.
5. CloudWatch 데이터소스, Backend↔AI 통합 추적, 실제 EKS 검증. 환경별 GitOps 연결은 제공했다.

위 순서는 구현 분할이며 합의된 관측성 기능을 제거한 것이 아니다.

## 2026-09-17 검증 결과

- 전체 Kubernetes 검증과 Stage·Prod Helm lint/render 및 관측성 계약 검사 통과.
- 보존 기간을 잘못 바꾼 임시 입력과 잘못된 CLI 옵션이 실패하는 것을 확인.
- 차트와 동일한 Prometheus v3.14.0 이미지로 로컬 서버 실행: Ready, 30개 규칙 그룹 로딩, self-scrape `up=1` 및 HTTP 조회 통과.
- `promtool check rules`는 차트 기본 `code_verb:apiserver_request_total:increase1h` 중복 이름을 lint 오류로 보고했다. 차트는 2xx/3xx/4xx/5xx를 서로 다른 `code` 조건으로 계산하고 출력에 `code`를 유지한다. 해당 기본 규칙을 변경하거나 lint 검사를 약화하지 않았다. 이 명령은 통과했다고 보고하지 않는다.
- 위 로컬 실행은 Kubernetes discovery, Operator reconciliation, Grafana 로그인, EBS/SG/NetworkPolicy, 실제 EKS 수집을 검증한 것이 아니다.

차트 옵션 근거: [고정 버전의 공식 values](https://github.com/prometheus-community/helm-charts/blob/kube-prometheus-stack-91.4.1/charts/kube-prometheus-stack/values.yaml).

## 경량화 반영

- Grafana sidecar 2개 제거: 요청량 40m/128Mi 절약. 차트 기본 대시보드 25개는 ConfigMap 디렉터리 마운트로 보존했다.
- Dashboard provider가 30초마다 파일을 다시 읽는다. kubelet의 ConfigMap 갱신 지연은 별도다. datasource/provider 설정은 Helm의 checksum/config 변경으로 재시작한다.
- 기본 대시보드 원본은 고정 Helm chart에 있다. 팀 JSON을 추가할 때 ConfigMap과 마운트를 함께 추가한다. 모든 ConfigMap이 마운트되었는지 CI가 검증한다.
- Rollouts Dashboard만 끈다. Controller 2개는 유지한다. 필요 시 로컬 `kubectl argo rollouts dashboard` 또는 CLI로 조회한다.
- `../collectors/log-buffer.alloy`는 로그 렌더러에서 Pod/Events 수집 경로에 연결했다. `trace-buffer.yaml`은 `../traces/stage`·`prod`의 OTel Collector 배포 설정에 연결했고, 실제 Tempo 저장소와 자동 배포는 아직 연결하지 않았다. 둘 다 실제 EKS 적용을 뜻하지 않는다.
- 로그 batch 256KiB, 활성 stream 1000, 재시도 3회. 전체 프로세스 메모리 상한을 뜻하지 않는다.
- 추적은 memory limiter 192Mi, batch 최대 1024 Span, 전송 큐 32요청, 재시도 최대 15초다. Span 크기는 가변이며 큐의 단위는 바이트가 아니다.
- Loki gateway/rules sidecar와 쿼리 동시 실행 수는 이번 변경 대상에서 제외했다.

경량화 로컬 검증: Grafana 13.2.2 HTTP API에서 datasource 2개와 기본 대시보드 25개를 확인했고, JSON 파일 제목 변경이 재시작 없이 반영되었다. datasource 변경 시 Deployment checksum 변화도 확인했다. Stage·Prod 전체 검증, Controller 2개 유지/Dashboard 제거 검사, Alloy v1.19.2 및 OTel Collector 0.160.0의 config validate를 통과했다. 버퍼 가득 참/장애 시 손실량과 실제 EKS 마운트 갱신은 아직 검증하지 않았다.

## CNPG · Argo 수집 추가

[Platform 수집·대시보드 안내](../platform/README.md)에 수집 대상 7개, 내부 포트, namespace 처리, 배포 순서와 EKS 검증 절차를 정리했다. Grafana 파일 provider에 Platform 폴더를 추가했고, metrics Application의 observability-assets chart가 기존 Backend/GPU JSON과 함께 CNPG/Argo JSON을 ConfigMap으로 공급한다. 검증 스크립트도 같은 Application sources를 렌더링한다. exporter Pod 추가는 없지만 시계열 저장·쿼리 비용은 추가된다. 전용 알림 규칙과 GitOps 연결을 제공했다. 외부 전송 및 실제 자동 동기화 활성화는 준비 완료 후 검증한다.

## 경보와 Discord 연결

[경보·Discord·Parameter Store 연결 안내](../alerts/README.md)에 초기 규칙과 인계 항목을 정리했다. 기본 metrics values는 외부 전송을 계속 끈다. Discord 전용 values는 SSM/IRSA 준비 후 명시적으로 추가하며, rules는 별도 Kustomize 묶음이다. CI는 실제 Webhook 없이 규칙과 환경별 파일 마운트·라우팅을 검사한다.
