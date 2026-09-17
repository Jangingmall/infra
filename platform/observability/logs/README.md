# Alloy → Loki 로그 수집

[노션 3.4 로그 설계](https://app.notion.com/p/c760842d874f83758b7b81f9766b276e)를 기준으로 한 Stage·Prod 공통 구현이다.
현재 자동 배포에는 미연결이다. 실제 S3/IRSA 인계와 전체 System 용량을 확인한 후 배포한다.

## 데이터 흐름

```text
App/AI/DB/Controller Pod의 stdout·stderr
 → 노드 containerd CRI 파일
 → Alloy DaemonSet (자기 노드 Pod만 발견)
 → CRI/JSON 파싱 + 본문/메타데이터 정리 + 공통 전송 버퍼
 → loki-gateway 내부 Service
 → Loki 단일 인스턴스 + EBS WAL/compactor 작업 공간 + S3 loki/
 → Grafana의 Loki 데이터소스

Kubernetes Events
 → Alloy Events Deployment 1개 (Recreate)
 → 같은 Loki gateway
```

- 노드 OS journal 전체를 수집하지 않는다. 명시한 namespace의 Pod 로그만 수집한다.
- 대상 namespace: app, ai, database, argocd, argo-rollouts, cnpg-system, kube-system, monitoring.
- DaemonSet은 Linux System/App/DB/GPU 노드에 배치한다. GPU/DB의 NoSchedule taint를 허용한다.
- Events는 별도 수집기 1개만 실행한다. 재시작/이벤트 갱신에서 중복 기록은 가능하며 exactly-once를 보장하지 않는다.
- 노드의 로그 파일은 read-only 마운트한다. 읽기 위치만 /var/lib/alloy-pod-logs에 기록한다. 노드 교체/Spot 종료 시 위치와 미전송 데이터는 유실될 수 있다.
- root는 containerd 로그 파일 읽기에 사용한다. privileged/hostPID와 Kubernetes Secret 조회 권한은 필요 없다.

## 파일과 실행 방법

| 파일 | 역할 |
|---|---|
| loki.yaml | Loki·gateway·rules sidecar, S3/IRSA·EBS·WAL·compactor 설정 |
| stage.yaml / prod.yaml | 7일 / 14일 보존 |
| alloy-pods.yaml / alloy-events.yaml | 노드별 로그 수집기 / 단일 Events 수집기 |
| pods.alloy / events.alloy | 실제 로그 처리 연결 |
| ../collectors/log-buffer.alloy | 공통 배치 크기·스트림·재시도 제한 |
| policies/ | 내부 ingress 제한과 수집기 ServiceMonitor |

```bash
bash scripts/render-logs.sh stage /tmp/janging-logs-stage
bash scripts/render-logs.sh prod /tmp/janging-logs-prod
bash scripts/validate-k8s.sh
```

렌더링만 수행하며 클러스터에 적용하지 않는다. 출력 디렉터리의 loki.yaml, alloy-pods.yaml, alloy-events.yaml, policies.yaml이 배포 대상 YAML이다. *.alloy는 검증용으로 결합한 원본이며 kubectl에 직접 적용하지 않는다.
렌더러는 Loki chart가 추가하는 불필요한 Secret 조회 권한을 제거한다. **chart 직접 설치 시 이 보정이 빠지므로 같은 렌더링 경로를 사용해야 한다.** 추후 GitOps 연결에서도 이 경로를 반영해야 한다.

고정 버전: Loki chart 7.3.0/image 3.6.11, Alloy chart 1.12.1/image v1.19.2.
차트의 appVersion과 실행 image tag가 다를 수 있어 실제 image를 명시했다.

## S3·IRSA·보존

- monitoring/logs-runtime ConfigMap에 실제 환경별 `LOKI_S3_BUCKET`을 제공한다. 버킷 이름은 비밀정보가 아니며 임의 AWS 리소스 이름을 만들지 않는다.
- monitoring/loki-sa에 환경별 실제 IRSA Role ARN을 연결한다. 장기 Access Key와 Pod Identity는 사용하지 않는다.
- 권한: 해당 버킷의 loki/* GetObject/PutObject/DeleteObject와 loki/ 범위 ListBucket. KMS 사용 시 해당 키 권한 별도.
- `storage_config.object_prefix: loki/`로 chunk·index·삭제 요청 저장 경로를 격리한다. index.prefix만 설정하는 것은 전체 S3 격리가 아니다.
- 해당 object_prefix는 고정 버전 소스에서 experimental로 표시된다. 실제 S3 key와 IAM 경계 검증을 배포 선행조건으로 둔다.
- ruler는 sidecar가 공급한 로컬 /rules 파일을 사용해 별도의 S3 rules/ 접근을 피한다. rules sidecar/gateway는 사용자 결정에 따라 유지했다.
- Compactor가 Stage 168h / Prod 336h 보존을 처리한다. S3 lifecycle은 이를 대신하지 않으며 더 긴 보조 기간을 인프라와 협의한다.
- Loki 10Gi PVC는 암호화 gp3-monitoring, Retain, PVC 자동 삭제 비활성이다. WAL·compactor 작업 공간은 장기 S3 보관과 별개다.
- SSE-S3와 Private 버킷이 초기 기준이다. S3 Public Access 차단은 인프라 담당이다.

## 라벨·조회 방법

인덱스: environment, namespace, service, container. Loki가 service_name/detected_level을 추가할 수 있다.
Pod/node/revision은 pack 단계에서 JSON 본문으로 이동한다. 원문은 `_entry`에 보존한다.
trace_id/span_id는 structured metadata로 보존한다. 검색 응답에는 라벨처럼 보여도 인덱스 라벨과 동일한 것은 아니다.

```logql
{environment="stage", namespace="app", service="backend"}
{service="backend"} | json | revision="<rollout hash>"
{service="backend"} | trace_id="<trace id>"
{service="backend"} | json | line_format "{{._entry}}" | json
{environment="stage", service="kubernetes-events"}
```

Stable/Preview 모두 수집하며 revision으로 구분한다. hash만 보고 active/preview 역할을 추측하지 않는다. 당시 Rollout의 stable/preview hash와 대조한다.
Tempo가 아직 없으므로 존재하지 않는 데이터소스로 이동하는 링크는 만들지 않았다. Tempo 구현 시 derivedFields/상호 조회를 연결한다.
Prod JSON의 level=DEBUG/TRACE만 필터링한다. 비JSON 로그와 INFO/WARN/ERROR는 유지한다.
토큰·암호·개인정보·Prompt 원문을 완벽하게 제거하는 범용 마스킹을 구현했다고 간주하지 않는다. Application팀은 원본에 민감값을 기록하지 않아야 하며 Stage 샘플 검토가 필요하다.

## 네트워크와 상태 관측

Loki는 내부 단일 tenant, auth_enabled=false다. 공개 Ingress를 만들지 않는다.
- Alloy/Grafana → gateway:8080 (Service는 80)
- gateway/Loki → Loki:3100·9095·7946
- Prometheus → Loki:3100 / Alloy:12345
- Alloy → Kubernetes API:443, Loki → S3/STS:443와 DNS는 실제 SG·endpoint/CIDR 인계 후 egress 제한과 대조한다. 이번 정책은 ingress만 제한한다.

ServiceMonitor는 monitoring namespace의 release=metrics 라벨을 사용한다. Prometheus Operator CRD가 먼저 필요하다.
Alloy 전송 실패/드롭과 Loki 수신·거부·저장 실패 메트릭을 확인한다. 공통 경보와 Discord 설정은 [alerts/](../alerts/README.md)에 작성했지만 로그 파이프라인 전용 실패/드롭 임계값은 별도 작업이다.

## 용량과 한계

System 2대의 Alloy DaemonSet은 reloader 포함 356Mi, Events 1개는 178Mi다.
Loki+rules sidecar+gateway는 1152Mi이므로 이 로그 구성의 System 요청 메모리 부분합은 **1686Mi**다.
이전 6952Mi 전체 후보에 새 Events 수집기 178Mi를 추가하면 **7130Mi**이며 누락된 EKS 애드온은 여전히 별도다.
현재 확정 구성은 t3.medium 1대 + t3.large 1대다. 기존 두 medium 계산은 비교 기록이며, 최신 배치와 누락 addon 비용은 [전체 용량 문서](../capacity.md)를 따른다. 실제 수용 가능성은 EKS에서 확인한다.

## EKS 검증 체크리스트

- [ ] 버킷·IRSA를 받은 후 다른 환경/tempo 경로 접근이 거부되는지 확인
- [ ] 실제 S3 객체 key가 loki/ 아래인지 확인; 압축·삭제 요청 경로도 포함
- [ ] CSI/PVC Bound 및 Loki 재시작 후 WAL·로그 조회 확인
- [ ] 각 노드의 허용 namespace 로그 수집; 금지 범위/노드 OS 로그는 미수집
- [ ] Backend Stable/Preview hash별 조회와 trace_id 검색
- [ ] Scheduling/ImagePull/PVC 등 테스트 Event 조회, Events 수집기 중복 배치 없음
- [ ] Prod DEBUG 제외, Stage DEBUG 유지, INFO/WARN/ERROR 유지
- [ ] 토큰·암호·개인정보가 샘플 로그에 없는지 Application팀과 확인
- [ ] NetworkPolicy 허용/거부, API/S3/STS 연결 확인
- [ ] Loki 장애 시 재시도 소진/드롭 및 복구 후 새 로그 전송 확인
- [ ] Compactor의 보존 삭제, 볼륨 증가량, 실제 메모리/OOM/T3 크레딧 확인

공식 근거: [Loki 저장 설정](https://grafana.com/docs/loki/latest/configure/), [Alloy Events 수집](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.kubernetes_events/).

## 2026-09-17 로컬 검증 결과

- Stage·Prod Loki/Alloy chart lint·render와 전체 Kubernetes 검증 통과.
- Loki 실제 바이너리의 S3 설정 유효성 검사 통과. 실제 AWS 인증/쓰기 검증은 아님.
- Alloy Pod/Events 설정 검사 통과. 실제 Kubernetes API Events 수집은 EKS에서 검증해야 함.
- 로컬 QA에서 저장소만 filesystem으로 바꾼 Loki에 실제 Alloy를 연결했다. Kubernetes discovery 대신 고정 테스트 CRI 파일을 사용했다.
- Stage INFO·DEBUG 2건, Prod INFO 1건을 Loki HTTP API로 조회했다. JSON 원문과 Pod/revision 본문, trace_id 메타데이터 보존 확인.
- Loki labels API에서 pod/node/revision/trace_id/span_id/filename이 인덱스 라벨에 없는 것을 확인했다.
- Grafana Loki 데이터소스는 렌더링 검증까지다. gateway·실제 S3/IRSA·Events·NetworkPolicy·EKS 디스크 및 장기 부하는 미검증이다.
