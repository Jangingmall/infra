# Backend 자원·자동 확장·DB 연결 예산

## 적용값

Stage·Prod가 동일한 base를 참조한다. Backend 소스와 Terraform은 변경하지 않는다.

| 항목 | 값 | 근거 |
| --- | --- | --- |
| requests | CPU 700m / 메모리 1Gi | BE 회신 CPU 600~700m, RAM 900Mi~1Gi 중 상단 선택 |
| limits | CPU 2 / 메모리 4Gi | 기존 설정 유지. 실제 기동·부하 측정 후 변경 여부 결정 |
| JVM heap | 컨테이너 메모리의 75%, 약 3Gi | 현재 Backend 이미지의 MaxRAMPercentage=75 사용. infra 고정 Xmx 없음 |
| HPA | min 2 / max 4 | 사용자 요청 및 기존 Q-CN-03의 확장 범위 유지 |
| HPA CPU 목표 | requests 대비 70% (490m/Pod) | 이번 초기 운영값, 부하 검증 후 조정 |
| 축소 안정화 | 300초 | 일시적 부하 하락에 의한 급격한 축소 완화 |
| HikariCP | 최대 10 / 최소 idle 5 / 연결 대기 3000ms | BE 회신을 Spring 환경변수로 명시 |
| CNPG max_connections | 200 | Q-CN-03 합의. 업무 DB 각 인스턴스에 적용 |

HPA는 Deployment가 아닌 `Rollout/backend`를 대상으로 한다. metrics-server와 Rollouts controller/CRD가 필요하다.
HPA는 노드 수를 늘리지 않는다. 리소스가 부족하면 replica 목표만 늘고 Pod는 Pending이 될 수 있다.
CPU 사용률에 따라 운영 목표를 2~4개로 조정한다. 이 범위는 운영 Pod 기준이며 구/신 버전 합산 상한이 아니다.
Rollout의 replicas=2는 최초 배포값이다. 향후 Argo CD 연결 시 `/spec/replicas`를 동기화에서 제외하고
`RespectIgnoreDifferences=true`를 구성해 HPA와 GitOps가 replica 수를 서로 되돌리지 않도록 한다.

## Blue/Green을 포함한 예산

`previewReplicaCount: 1`은 승격 전 대기 중인 Preview 수다. 승격할 때 신버전은 desired replicas까지 증가한다.
기존 버전은 전환 후 60초 동안 남는다. `scaleDownDelayRevisionLimit: 1`로 축소 대기 구버전 누적을 제한한다.

| 상황 | Pod 수 | CPU requests 합 | 메모리 requests 합 | 앱 풀 최대 연결 |
| --- | ---: | ---: | ---: | ---: |
| 평상시 최소 | 2 | 1400m | 2Gi | 20 |
| 최소 운영 + Preview | 3 | 2100m | 3Gi | 30 |
| 최소 운영 승격 중 | 2 + 2 = 4 | 2800m | 4Gi | 40 |
| HPA 최대 운영 | 4 | 2800m | 4Gi | 40 |
| 최대 운영 + Preview | 5 | 3500m | 5Gi | 50 |
| 최대 운영 승격 중 | 4 + 4 = 8 | 5600m | 8Gi | 80 |

마지막 행은 단일 정상 전환의 계획값이며, 종료 중 Pod나 장애·연속 배포까지 포함한 절대 상한은 아니다.
구버전 종료와 연결 해제를 확인한 뒤 다음 승격을 진행한다.
최소 idle=5이므로 8개 Pod에서는 idle 목표만 40개다. 실제 연결 수는 부하와 풀 상태에 따라 달라진다.

200 - 앱 풀 80 = 120은 단순 산술 여유다. 관리자 예약·운영 도구·마이그레이션 등 추가 SQL 연결을 고려한다.
스트리밍 복제의 walsender 연결 예산은 `max_wal_senders`도 별도로 확인한다.
DB가 replica 3개라고 쓰기 Primary의 연결 상한이 600개가 되는 것은 아니다.
AI 전용 벡터DB는 별도 DB이므로 이 업무 DB 예산에 포함하지 않는다.

## 배포 전 해결 조건

**현재 App은 t3.medium 2대이며 이 문서의 수량은 환경별 전용 노드 기준이다.**
700m Pod는 한 노드당 최대 2개이므로 HPA max 4에서 Preview를 추가하면 배치 공간이 없다.
**HPA 2~4는 적용하지만 최대 확장 상태의 Blue/Green 용량은 미해결이다. CI 통과는 배포 가능 판정이 아니다.**
운영 4 + 신규 4를 수용할 추가 App 용량을 인프라 담당과 확보하거나, 배포 전략을 별도 합의해야 한다.
운영 2개에서 시작해도 배포 도중 HPA 목표가 증가할 수 있다. 시작 시 Pod 수 확인만으로 충분하지 않다.
부하가 높은 상태에서 공간 확보를 위해 운영 Pod를 임의 축소하지 않는다.
이번 관측성 PR에서는 Backend 배치 정책을 변경하지 않는다. 실제 노드별 Pod 배치를 별도로 확인한다.
다음 계산은 노드당 Backend가 2개인 경우이며 위 8개 Pod의 배포 용량을 보장하지 않는다.
requests 기준 노드당 CPU 1400m / RAM 2048Mi지만 Backend memory limits 합계는 8Gi다.
medium 노드 한 대의 물리 메모리는 4GiB이고 실제 allocatable은 그보다 작다.
따라서 Pod가 requests 기준으로 배치되어도 4Gi limit까지 안전하게 사용할 수 있다는 뜻은 아니다.
기존 limit을 유지하는 결정이며 용량 문제가 해결된 것은 아니다. 실제 addon 자원과 Backend 최대 사용량을 함께 측정한다.
노드 하나가 사라졌을 때 정상 용량/무중단 배포는 보장하지 않는다. System/DB/GPU로 우회하지 않는다.

Backend 소스/이미지는 수정하지 않고, infra에서 고정 Xmx를 주입하지 않는다.
현재 Dockerfile의 UseContainerSupport 및 MaxRAMPercentage=75로 4Gi × 75% ≈ 3Gi의 힙 상한을 계산한다.
계산 기준은 requests 1Gi나 노드 전체 RAM이 아니라 JVM이 인식한 컨테이너 메모리 한도다.
남은 약 1Gi의 native/non-heap 예산은 별도 강제 제한이 아니며 전체가 4Gi를 넘으면 OOMKilled될 수 있다.
컨테이너 한도에 도달하기 전에도 노드 전체 메모리가 부족하면 종료 또는 축출될 수 있다.
비율 계산은 limit 변경에 따라 힙도 조정되지만, 비힙 메모리가 항상 나머지 25% 안에 들어간다는 보장은 없다.
새 이미지의 JVM 옵션이 바뀌면 비율을 다시 확인한다. infra 정적 검증은 이미지 내부 옵션까지 보증하지 않는다.
BE팀이 제공한 900Mi~1Gi는 requests 범위이며 최대 사용량 근거가 아니다. 이를 이유로 limit을 축소하지 않는다.
BE팀과 JVM heap/GC/프로세스 RSS/컨테이너 working set을 확인한 뒤 limit·노드 크기·배포 용량을 함께 결정한다.
CNPG max_connections=200 또한 처리량·메모리 안전성을 보장하지 않으므로 DB 부하 검증이 필요하다.

## 검증 순서

1. 로컬: `bash scripts/validate-k8s.sh`로 두 overlay와 플랫폼 차트를 렌더링한다.
2. EKS: metrics-server와 Rollouts controller가 준비되었는지, `kubectl -n app describe hpa backend`에서 CPU 메트릭이 나오는지 확인한다.
3. 노드 allocatable에서 DaemonSet 등 기존 requests를 빼고 위 표를 수용하는지 확인한다.
4. Backend 시작 후 적용된 풀 설정과 Hikari 메트릭을 확인한다. 비밀번호·전체 환경변수를 출력하지 않는다.
5. 업무 DB에서 `SHOW max_connections`가 200인지 확인한다. 기존 DB 변경 시 CNPG 재시작 동작을 확인한다.
6. Stage 부하에서 HPA 2→4 확장과 안정화 후 축소, JVM heap/GC 및 CPU throttling을 확인한다.
7. 별도 배포 용량을 확보한 뒤 Preview 생성·승격·구버전 종료를 검증한다. Pod 수, Pending/OOM, DB 연결 수를 기록한다.

이 단계에서는 실제 EKS 배포·부하 테스트를 수행하지 않는다. Secret·이미지·Redis 등 기존 실행 의존성도 별도로 준비해야 한다.

## 근거

- [BE 자원·HikariCP 회신](https://app.notion.com/p/6820842d874f8216819701e9749724a0)
- [Q-CN-03 HPA·DB 연결 상한](https://app.notion.com/p/3dd0842d874f8091a9cfe5b8efafaa21)
- [Argo Rollouts HPA](https://argoproj.github.io/argo-rollouts/features/hpa-support/)
- [Blue/Green 승격](https://argoproj.github.io/argo-rollouts/features/bluegreen/)
