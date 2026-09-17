# CNPG · Argo 메트릭 수집과 대시보드

## 무엇을 왜 보는가

서비스 장애는 Backend 코드 외에도 DB 연결 고갈이나 배포 실패에서 시작할 수 있다. 기존 프로세스가 제공하는 메트릭을 Prometheus가 30초마다 읽고 Grafana의 `Platform` 폴더에 표시한다. 별도 exporter Pod나 Grafana sidecar를 추가하지 않는다.

| 수집 설정 | 대상 | Pod 포트 | 관측 목적 |
| --- | --- | --- | --- |
| PodMonitor cnpg-database | database의 jangingmall-postgres DB 3개 | 9187 | DB 응답, Primary/Replica, 연결 수와 상한 대비 사용률, 복제 지연, 트랜잭션, 교착 상태, WAL, SQL 수집 오류 |
| PodMonitor cnpg-operator | cnpg-system의 CNPG Operator | 8080 | Operator 메트릭 수집 가능 여부 |
| ServiceMonitor argocd-controller | Argo CD Application Controller | 8082 | Application Sync/Health, 동기화 실행률, 조정 시간 |
| ServiceMonitor argocd-server | Argo CD API Server | 8083 | 수집 상태와 프로세스 CPU/메모리 |
| ServiceMonitor argocd-repo-server | Argo CD Repo Server | 8084 | 수집 상태와 프로세스 CPU/메모리 |
| ServiceMonitor argocd-applicationset | ApplicationSet Controller | 8080 | 수집 상태와 프로세스 CPU/메모리 |
| ServiceMonitor argo-rollouts | Rollouts Controller 2개 | 8090 | Backend 배포 상태, 목표/가용/최신 버전 Pod 수, 조정 오류와 작업 대기열 |

설정 7개가 실제 Endpoint 7개라는 뜻은 아니다. DB 3개, Rollouts Controller 2개 등 복제 수에 따라 수집 Endpoint가 늘어난다. PVC 사용률은 기존 kubelet 수집의 `kubelet_volume_stats_*`를 재사용한다.

## 파일 역할

- `monitors.yaml`: Prometheus에 수집 대상, namespace, label, 포트를 알려준다. 모든 Monitor는 monitoring namespace, `release: metrics`를 사용한다.
- `network-policies.yaml`: 대상 Pod의 메트릭 포트를 monitoring의 해당 Prometheus Pod에 허용한다.
- `kustomization.yaml`: 두 리소스 파일을 묶는다. 정책별 namespace를 보존해야 하므로 namespace 일괄 덮어쓰기를 하지 않는다.
- `cnpg-dashboard.json`: DB 상태 대시보드. 백업 미구현 안내를 포함한다.
- `argo-dashboard.json`: GitOps/Blue-Green 배포 상태 대시보드.
- `../metrics/values.yaml`: 파일 기반 Platform dashboard provider. JSON은 Helm `--set-file` 입력으로 공급한다.
- `../../../scripts/validate-platform-monitoring.rb`: 고정 차트의 실제 Service selector → Pod label → containerPort와 정책을 대조한다.

## 구현에서 주의한 점

### CNPG 수집에는 앱 DB 비밀번호를 추가하지 않는다

CNPG에 내장된 exporter를 사용한다. 앱 Secret 복제나 별도 PostgreSQL exporter를 만들지 않는다. CNPG 1.30에서 deprecated된 Cluster의 `enablePodMonitor` 대신 독립 PodMonitor를 선언했다. 기본 SQL 지표는 고정 CNPG 차트가 공급하는 쿼리를 기준으로 작성했다.

연결 사용률은 실제 `max_connections` 메트릭을 분모로 사용한다. 현재 합의값 200을 그래프 계산식에 하드코딩하지 않는다. WAL 사용량은 백업 성공 증거가 아니다. 백업/S3/WAL archive 구현과 복구 검증이 남아 있으므로 오래된 backup timestamp 지표로 성공 패널을 만들지 않았다.

### namespace와 Pod 수를 잘못 해석하지 않는다

Prometheus의 `namespace`는 수집 대상 Controller가 실행되는 namespace다. Argo 메트릭 내부의 같은 이름 label은 관측 중인 Application/Rollout의 namespace다. `honorLabels: false`를 유지하고 충돌한 `exported_namespace`를 `resource_namespace`로 옮긴다. Backend Rollout은 `resource_namespace="app"`으로 조회한다.

Controller 두 대가 같은 Rollout의 Pod 수를 보내더라도 합산하지 않고 `max`로 중복 제거한다. 카운터는 개별 시계열의 증가율을 먼저 계산한다. `updated`는 최신 Pod template에 해당하는 수이며 Preview 전용 Pod 수와 같지 않다. Stable/Preview를 정확히 분리하는 패널은 실제 revision/service 연결을 확인한 후 추가해야 한다.

DB 응답/역할/수집 상태는 현재 값을 한글 상태 카드와 색상으로 표시한다. 과거 추이는 연결 수·복제 지연 등의 시계열 그래프에서 확인한다.

Argo의 p95는 Controller의 리소스 조정 시간이다. 사용자 API 응답시간 p95가 아니다. 관측 이벤트가 없어 NaN인 값은 필터링해 No data로 표시하며 0초로 대체하지 않는다. `up=1`도 수집 성공을 뜻하며 앱 전체의 정상 동작을 보장하지 않는다.

### 메트릭 정책과 전체 통신 정책은 다르다

메트릭 포트에는 Prometheus 출발지 조건을 적용했다. DB의 기존 5432/8000 허용 정책과는 합산된다. 메트릭 정책을 추가하면서 기존 제어 통신까지 갑자기 차단하지 않도록 CNPG webhook 9443, Argo Server 8080, Repo Server 8081, ApplicationSet 7000/8081, Rollouts health 8080은 출발지 제한을 새로 추가하지 않았다.

이 제어 포트 허용은 전체 최소권한 NetworkPolicy가 완료됐다는 뜻이 아니다. 전체 NetworkPolicy 단계에서 API server, ALB, Controller 등 실제 호출자와 SG를 확인해 좁혀야 한다. 정책은 합산되므로 다른 broad allow가 있으면 메트릭 접근도 다시 넓어질 수 있다. Prometheus에 egress 격리를 추가할 때는 위 수집 포트를 함께 허용해야 한다. 이번 묶음은 새로운 egress 격리를 만들지 않는다.

## Stage · Prod 적용 순서

현재 코드는 두 환경에서 재사용할 공통 설정이다. 실제 클러스터에 적용하지 않았고 Argo Application 자동 동기화 경로에도 아직 연결하지 않았다.

1. Prometheus Operator와 PodMonitor/ServiceMonitor CRD, monitoring namespace를 준비한다.
2. 기존 설치 경로로 CNPG/Argo 차트를 배포한다. Argo CD의 변경된 values로 메트릭 Service를 활성화한다. 차트 자동 ServiceMonitor는 중복 수집 방지를 위해 비활성화한다.
3. metrics 차트를 환경별 values와 기존 dashboard 입력에 더해 아래 두 입력으로 렌더링/배포한다. 기존 Backend/GPU dashboard 입력을 빼면 안 된다.

```sh
--set-file grafana.dashboards.platform.cnpg.json=platform/observability/platform/cnpg-dashboard.json \
--set-file grafana.dashboards.platform.argo.json=platform/observability/platform/argo-dashboard.json
```

4. `kubectl kustomize platform/observability/platform` 결과를 검토하고 해당 환경에 적용한다. GitOps 연결 시에도 동일 경로와 설치 순서를 사용한다.
5. Grafana Platform 폴더와 Prometheus Targets를 확인한다.

릴리스 이름은 `metrics`, `argocd`, `argo-rollouts`, `cloudnative-pg`를 전제로 한다. 다른 이름으로 설치하면 selector도 함께 변경해야 한다. Stage/Prod가 같은 Prometheus를 공유하도록 바뀌면 cluster/environment label과 대시보드 필터를 추가해야 한다.

## 검증 결과와 한계

2026-09-17 로컬 확인:

- `bash scripts/validate-k8s.sh`: Stage/Prod Kustomize, Helm lint/render와 전체 기존 검증 통과.
- 고정 차트의 실제 Service/Pod label, 메트릭 port, Monitor 7개와 NetworkPolicy 대조 통과.
- 차트 버전과 같은 Prometheus v3.14.0에서 두 대시보드의 PromQL 26개 문법 검사 통과.
- 로컬 HTTP fixture → Prometheus 실제 scrape에서 Endpoint 10개 UP 확인.
- 시험용 연결 100/200이 50%, 20/200이 10%로 계산됨을 확인.
- Controller 두 대의 동일 목표 Pod 2개를 4개가 아닌 2개로 조회하고 `resource_namespace=app` 보존 확인.
- 시험용 DB 응답을 실패로 바꿨을 때 `cnpg_collector_up=0`, HTTP 수집은 계속 `up=1`로 구분됨을 확인하고 fixture를 복원했다.
- Grafana 13.2.2에 실제 JSON 파일을 마운트해 대시보드 표시 확인. 이 데이터는 시험용이며 실제 DB/Argo 상태가 아니다. PVC 미수집 및 이벤트가 없는 p95는 정상값으로 대체하지 않았다.

실제 EKS에서 반드시 확인할 것:

1. 모든 의도한 Endpoint의 UP과 중복 scrape 부재.
2. 실제 PostgreSQL 연결 수/역할/복제 지연을 SQL 및 CNPG 상태와 비교.
3. App Sync/Health와 Rollout 상태/Pod 수를 Kubernetes/Argo 조회 결과와 비교.
4. 허용된 Prometheus의 수집과 다른 Pod의 메트릭 접근 차단을 각각 시험.
5. CNPG webhook, Argo UI/API, Repo Server, ApplicationSet, Rollout 제어 통신 회귀 확인.
6. DB 장애/복제 지연/배포 실패 시 차트 변화와 No data 상황 확인.
7. Prometheus 메모리·TSDB 증가와 System 노드 용량 측정. 새 Pod는 없지만 시계열 추가 비용은 있다. 현재 용량 산정의 부족분이 해소된 것은 아니다.

전용 경보 규칙과 Discord 설정은 [alerts/](../alerts/README.md)에 작성했다. 실제 SSM/IRSA·외부 채널 연결, 백업 관측, Tempo 저장소, CloudWatch, Backend↔AI 추적, 자동 배포 연결과 EKS 검증은 남아 있다. 관측성 전체가 완료된 것은 아니다.

## 기준 문서

- [합의된 관측성 설계](https://app.notion.com/p/c760842d874f83758b7b81f9766b276e)
- [CNPG 1.30 모니터링](https://github.com/cloudnative-pg/cloudnative-pg/blob/v1.30.0/docs/src/monitoring.md)
- [Argo CD 3.5.3 메트릭](https://github.com/argoproj/argo-cd/blob/v3.5.3/docs/operator-manual/metrics.md)
- [Rollouts 1.10.0 메트릭 정의](https://github.com/argoproj/argo-rollouts/blob/v1.10.0/controller/metrics/prommetrics.go)
