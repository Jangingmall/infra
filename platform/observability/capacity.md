# System 노드 관측성 용량 검토

2026-09-17. 코드/차트 렌더링에 의한 사전 검토이며 실측 또는 배포 승인이 아니다.

## 현재 확정 구성과 적용 (2026-09-17 갱신)

**이 절이 아래의 이전 medium 2대 계산보다 우선한다. 아래 기록과 sizing/는 변경 전 비교 자료다.**

### Tempo 배포 기반 추가

`tempo/values.yaml`에 community chart 2.4.0 / Tempo 2.10.8 단일 컨테이너를 작성했다.
requests 250m/768Mi는 기존 전체 후보에 포함된 Tempo 예산을 사용하므로 합계에 중복 가산하지 않는다.
limit은 CPU 1 / 1536Mi이며, 1Gi 기본 memory ballast는 끄고 Go 메모리 목표는 1152MiB로 제한했다.
WAL용 gp3 10Gi는 초기 제안이다. S3 전체 보존 데이터 크기와 다르며 유입량/장애 기간으로 검증해야 한다.
System selector와 저장 Pod 간 soft 분산만 사용한다. medium/large 어느 노드에 실제로 들어갈지는 기존 Pod·allocatable·PVC AZ에 달려 있다.
아래의 '미구현 Tempo'와 deprecated chart 기록은 이 변경 전 산정 이력이다. 실제 EKS 용량·HA 검증 완료를 의미하지 않는다.

| 구분 | 환경별 노드 | 물리 메모리 | 물리 CPU |
| --- | --- | ---: | ---: |
| System | t3.medium 1 + t3.large 1 | 12GiB | 4 vCPU |
| App | t3.medium 2 | 8GiB | 4 vCPU |

Stage·Prod는 각각 이 노드 구성을 가진다고 계산한다. 같은 노드를 두 환경이 공유하면 다시 합산해야 한다.
large도 2 vCPU이므로 메모리만 증가했으며 CPU 수는 이전과 같다.

### 코드에 반영한 배치

| 대상 | 배치 방식 | 이유/한계 |
| --- | --- | --- |
| Prometheus | System이면서 instance-type=t3.large인 노드 필수 | 가장 큰 메트릭 저장 Pod를 large에 배치. large 부재나 PVC AZ 불일치 시 Pending |
| Loki | System, t3.medium 우선 + 저장 Pod끼리 hostname 분산 우선 | Prometheus와 분산하되 자원/PVC 조건에 따라 large도 허용 |
| Grafana·Alertmanager·Argo CD·Collector 등 | System 내 가용 requests 기준 | 전부 medium에 고정하지 않으며 최종 위치는 스케줄러가 결정 |
| CNPG Operator | System, requests 100m/128Mi, limit 256Mi | 기존 미지정 예산을 선언. DB Pod 자원과 별개 |
| Rollouts Controller | System, replica당 requests 100m/128Mi, limit 256Mi | 두 replica의 합계 200m/256Mi. 기존 hostname 우선 분산 유지 |

기존 전체 후보 **7130Mi**에는 이번에 선언한 Controller 예산 384Mi와 미구현 Tempo 예산 768Mi가 이미 포함돼 있다.
따라서 중복 가산하지 않는다. Tempo를 뺀 해당 후보는 6362Mi지만 이것도 모든 EKS addon을 포함한 실측값은 아니다.
12GiB(12288Mi)와 7130Mi의 차이는 5158Mi이며, 이는 사용 가능한 여유 메모리가 아니다.
OS/Kubernetes 예약, 누락된 addon, 요청량 초과 사용량 및 업데이트 중 일시 Pod 비용을 추가해야 한다.
새 large의 allocatable은 추정값을 확정하지 않고 EKS Node.status.allocatable로 확인한다.

### 배포 전 확인

1. `kubectl get nodes -L workload-type,node.kubernetes.io/instance-type,topology.kubernetes.io/zone`으로 노드 타입/역할/AZ 확인.
2. `kubectl describe node <노드이름>`에서 각 노드 allocatable 및 이미 배치된 Pod requests/limits 확인.
3. Prometheus PVC가 large의 AZ에 연결될 수 있는지 확인. 이미 다른 AZ에 만들어진 PVC는 selector 수정만으로 이동하지 않는다.
4. Loki와 나머지 관리 프로그램의 실제 배치를 확인. soft 분산은 보장이 아니며 합계가 맞아도 특정 노드는 부족할 수 있다.
5. metrics/log 유입과 쿼리 실행 중 working set, OOM, Pending, CPU throttling/credits 확인.
6. large 장애 시 medium 한 대에 전체 스택을 수용할 수 없음을 운영 절차에 반영한다.

App의 HPA 2~4, JVM 비율 계산 및 운영 4개에서 부족한 배포 용량은 [Backend 예산](../../k8s/base/backend/README.md)에 정리했다.
이번 작업은 infra YAML/문서 변경이며 Terraform 변경·실제 배포를 포함하지 않는다.

## 용량 기준

사용자 구조도: t3.medium 2대, 각 2 vCPU/4GiB, allocatable 메모리 약 3554Mi. 합계 7108Mi.
이 allocatable은 가정이며 실제 Node.status.allocatable로 확인해야 한다. CPU allocatable은 미확인이다.
allocatable에서 kube/system reserved를 다시 빼지 않는다. 그러나 그 위에 스케줄되는 시스템 Pod requests는 별도로 계산한다.
20% 운영 여유를 가정하면 총 Pod requests 예산은 약 5686Mi. 20%는 이 문서의 계획 가정이며 팀 확정값이 아니다.

## 기존 코드에서 확인한 requests

| 구성 | 수량 | 전체 CPU | 전체 메모리 | 근거 |
|---|---:|---:|---:|---|
| Argo CD 상시 구성 | 5 Pod | 550m | 1152Mi | platform/argocd/values.yaml |
| CSI Driver + AWS Provider | 노드당 2 Pod × 2노드 | 240m | 480Mi | AWS chart 3.1.3 렌더링 |
| CNPG Operator | 1 | 미지정 | 미지정 | chart 0.29.0, resources={} |
| Rollouts Controller | 2 | 미지정 | 미지정 | chart 2.43.1, resources={} |
| Rollouts Dashboard | 1 | 미지정 | 미지정 | chart 2.43.1, resources={} |
| Argo CD Redis 초기화 Job | 일시 1 | 50m | 64Mi | 설치 시 추가 |
| CSI CRD 관리 Job | 일시 | 미지정 | 미지정 | chart 3.1.3 |

확인된 상시 부분합은 790m / 1632Mi. 이것은 전체 시스템 사용량이 아니다.
추가 확인: VPC CNI(aws-node), kube-proxy, CoreDNS, EBS CSI Controller/Node, ALB Controller, Metrics Server 및 실제 설치된 노드 관리 Controller.
미지정은 0 사용을 의미하지 않는다. CPU/메모리 limits도 requests와 별도로 검토해야 한다.
DCGM은 GPU 노드에 배치하므로 System 노드 예산에는 포함하지 않는다.

## 관측성 초기 requests 후보

아래는 계산을 시작하기 위한 제안이며 벤더 최소 요구량·실측치·최종 Helm values가 아니다.
로그/Trace는 작은 단일 인스턴스 구성, 숨은 cache/gateway/sidecar가 없는 것으로 단순화했다.
최종 chart 렌더링에서 모든 컨테이너, init container, Job, cache, gateway가 추가되면 재계산해야 한다.

| 구성 | 수량 | 전체 CPU | 전체 메모리 |
|---|---:|---:|---:|
| Prometheus | 1 | 500m | 1536Mi |
| Grafana | 1 | 100m | 256Mi |
| Alertmanager | 1 | 50m | 128Mi |
| Prometheus Operator | 1 | 100m | 128Mi |
| kube-state-metrics | 1 | 50m | 128Mi |
| Loki | 1 | 500m | 1024Mi |
| Tempo | 1 | 250m | 768Mi |
| OTel Collector | 1 | 100m | 256Mi |
| Alloy | System 노드의 2개분 | 200m | 256Mi |
| node-exporter | System 노드의 2개분 | 60m | 128Mi |
| 합계 | | 1910m | 4608Mi |

Alloy/node-exporter가 App/DB/GPU에도 실행되는 비용은 각 해당 노드에 추가한다. Events 수집은 중복 수집 방지 방식과 그 자원을 최종 chart 설계에 반영한다.

## 사전 계산 결과

확인된 기존 부분합 1632 + 신규 후보 4608 = 6240Mi.
7108 - 6240 = 868Mi만 남는다. 아직 여러 필수 시스템 Pod가 빠진 숫자다.
20% 여유 기준 5686Mi와 비교하면 누락분을 넣기 전부터 약 554Mi 초과한다.
CPU 부분합도 790 + 1910 = 2700m이며 미확인 시스템 Pod가 추가된다.
따라서 현재 후보 전체 스택을 t3.medium 2대에 여유 있게 배치할 수 있다고 결론 내릴 수 없다.

T3는 burstable이다. t3.medium baseline은 vCPU당 20%, 24 credits/hour이며 두 노드 합산 지속 baseline은 약 0.8 vCPU이다.
CPU requests 2700m가 실제 2.7 CPU 사용을 뜻하지는 않는다. 그러나 실제 지속 CPU 사용이 baseline을 넘으면 credit/Unlimited 과금 동작을 검증해야 한다.

## 두 노드의 배치 원칙

- 모든 중앙 구성은 workload-type=system을 사용한다. IP나 nodeName 고정은 피한다.
- Prometheus와 Loki 같은 무거운 Pod는 서로 다른 hostname에 배치되도록 우선 분산한다.
- Argo CD 전체를 Loki/Tempo 노드에 몰지 않는다. 각각의 Pod requests를 기준으로 분산한다.
- Controller의 여러 replica는 hostname 기준 분산한다. replica가 하나인 컴포넌트에 topology spread만 붙여도 HA가 되는 것은 아니다.
- strict anti-affinity는 노드 부족 시 Pending을 만들 수 있다. soft 분산은 강제 보장이 아니다.
- EBS PVC의 AZ와 두 노드의 AZ를 함께 확인한다. CPU/메모리 빈 공간만으로 재배치 가능한 것은 아니다.
- 한 노드 장애 시 전체 스택 유지(N+1)는 이 계획으로 보장하지 않는다.

현재 용량이 검증되지 않아 A/B별 최종 배치표와 Helm 자원값은 확정하지 않는다.

## 다음 작업과 인프라 인계

1. 미지정 Controller의 초기 requests와 EKS addon 버전/설정 확인.
2. 전체 관측성 chart를 고정하고 sidecar/cache까지 렌더링해 합산.
3. 노드별 배치와 여유를 재계산. 작은 requests로 스케줄만 성공시키지 않는다.
4. 전체 Metrics/Logs/Traces 범위를 유지하려면 System 노드 메모리 증설을 인프라와 협의한다. 비교 후보로 8GiB 노드 2대를 산정하되, 인스턴스 유형/비용/CPU baseline은 별도 확인한다. 확정 권고 크기나 비용 견적이 아니다.
5. 인프라 변경 없이 진행할 경우 어떤 범위를 줄일지는 사용자/팀 결정이다. Tempo 등 합의된 기능을 임의 제외하지 않는다.
6. 실제 EKS에서 ingested series/logs/spans, 쿼리 부하, CPU credits, OOM, 노드 장애를 확인한다.

참고:
- https://aws.amazon.com/ec2/instance-types/t3/
- https://prometheus.io/docs/prometheus/latest/storage/
- Phase3 설계: https://app.notion.com/p/c760842d874f83758b7b81f9766b276e

## 2차 검토: 실제 차트 렌더링 (2026-09-17)

위 1차 제안표를 보완하는 결과이며 최종 배포값은 아니다.
`sizing/charts.yaml`에 공식 저장소에서 조회한 산정용 버전을 고정했다.
`sizing/*.yaml`은 배포 금지인 계산용 values다. Argo CD/CI의 배포 진입점과 연결하지 않았다.

추가로 발견한 상시 자원:
- Grafana dashboard/datasource sidecar 2개: 총 40m/128Mi.
- Alloy config-reloader 2개(System 노드분): 총 20m/100Mi.
- Loki gateway: 50m/64Mi. 단일 Loki 구성을 사용하며 별도 chunks/results cache는 제외.
- Loki rules sidecar: 20m/64Mi로 산정.
- Prometheus/Alertmanager config-reloader: 총 20m/100Mi. Operator 인자로부터 추론한 값이며 Helm은 최종 StatefulSet을 직접 생성하지 않는다. 실제 Operator reconciliation 시 재확인 필요.

관측성 후보 합계: 2060m/5064Mi.
기존 790m/1632Mi + CNPG/Rollouts/Dashboard 요청량 제안 350m/512Mi를 합하면 **3200m/7208Mi**.
미확인 CNI/CoreDNS/kube-proxy/EBS CSI/ALB/Metrics Server 및 일시 Job을 제외하고도 **7108Mi보다 100Mi 초과**한다.
20% 여유 목표 5686Mi와 비교하면 1522Mi 초과이며, 누락 애드온 자원이 추가되어야 한다.
따라서 이 전체 스택 후보의 A/B 분배는 현재 두 노드에 성립하지 않는다. 분산 설정으로 전체 용량 부족을 해결할 수 없다.

### 검토 한계/후속 결정

- 현재 Terraform EKS 코드에서 addon 버전 및 configuration_values 선언을 확인하지 못했다. 설치된 값을 추측하지 않는다. 인프라에게 CNI/CoreDNS/kube-proxy/EBS CSI/Metrics Server/ALB Controller의 버전, replica, resources, 배치 설정을 요청해야 한다.
- Prometheus admission Job resources는 미지정이다. init container/업데이트 surge 및 Kubernetes pod overhead까지 최종 배포 모델에서 재계산한다.
- Tempo chart 1.24.4는 공식 metadata에 deprecated=true다. 이 버전은 용량 비교 증거로만 남긴다. 실제 구현 전에 유지보수되는 배포 경로를 선정하고 다시 렌더링해야 한다.
- Loki Chart 7.3.0의 appVersion은 3.6.12지만 values의 기본 이미지 태그는 3.6.11로 관찰됐다. Chart appVersion을 실제 실행 이미지 버전으로 단정하지 않는다.
- 로그/Trace pipeline, S3 인증·보존·보안과 limits는 이 산정용 values에서 완성하지 않았다. 절대 배포하지 않는다.
- 단일 인스턴스 크기와 작은 requests는 부하를 버틴다는 보장이 아니다. Stage 100% Trace는 실제 유입량에 따라 조정/증설이 필요하다.

### 인프라 전달 문안 (전송하지 않음)

System t3.medium 2대의 구조도상 allocatable 합계 7108Mi에 대해, Metrics/Logs/Traces 전체 구성의 산정 요청량이 최소 7208Mi이며 EKS 애드온 일부가 아직 제외되어 있습니다. 현 크기로 해당 후보를 배치하기 어렵습니다. System 노드 크기 상향/증설 후보와 addon별 설정을 공유 부탁드립니다. 8GiB 노드 2대를 비교 후보로 검토하되 CPU 지속 성능·비용·AZ·한 노드 장애 시 유지 범위까지 함께 판단해야 합니다. Terraform 변경은 인프라 담당 범위로 남깁니다.

## 선택한 경량화 반영

Grafana sidecar 제거로 요청량 40m/128Mi를 줄였고 Rollouts Dashboard를 비활성화했다.
Dashboard의 기존 실제 requests는 미지정이므로, 제거 효과 50m/128Mi는 위 산정 제안값에서 빼는 수치다.
현재 전체 후보는 7208 - 128 - 128 = **6952Mi**이며, 누락된 EKS 애드온과 일시 Pod를 더해야 한다.
7108Mi보다 작아졌다는 이유만으로 배포 여유가 확보되었다고 판단하지 않는다.
버퍼 제한은 실행 중 메모리 폭증을 줄이기 위한 설정이며 requests 절감으로 계산하지 않는다.
Loki gateway/rules 보조 구성과 검색 동시 실행 수는 유지했다. sizing/의 이전 결과는 변경 전 비교 증거다.

## 로그 파이프라인 구현 후 추가 비용

Events 중복 수집 방지를 위해 System에 Alloy Events Deployment 1개를 추가했다.
요청량은 Alloy 50m/128Mi + reloader 10m/50Mi = 60m/178Mi다.
이전 전체 후보 6952Mi + 178Mi = **7130Mi**로, 기존 예상 allocatable 7108Mi를 다시 초과한다.
일부 EKS 애드온/일시 Job은 여전히 빠져 있다. 두 t3.medium에서 전체 스택을 배포 가능하다고 간주하지 않는다.
Loki 구성은 gateway/rules sidecar를 유지했으며 버퍼 한도를 낮춘 효과를 requests 절약으로 환산하지 않았다.

## GPU·Trace 수신 기반 작성 후

DCGM Exporter는 GPU 노드마다 requests 100m/128Mi를 추가한다. L40S/T4 두 노드면 GPU 쪽 총 200m/256Mi이며 System 합계에 포함하지 않는다.
Collector Deployment requests 100m/256Mi는 기존 표의 Collector 1개와 동일해 중복 가산하지 않는다. limit은 384Mi다.
따라서 기존 전체 후보 7130Mi 및 누락 애드온 문제는 그대로 남는다. 대시보드는 기존 Grafana 파일로 제공해 sidecar를 늘리지 않는다.
Tempo는 배포하지 않았다. 전체 후보에 있던 Tempo 768Mi는 실제 버전/배포 방식/부하 검증 전의 예산이며 구현 완료로 간주하지 않는다.
