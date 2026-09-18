# Trace 수신 기반: 네이티브 단독 구현 범위

## 현재 상태

[노션 9장 설계](https://app.notion.com/p/c760842d874f83758b7b81f9766b276e)에 맞춰
`Backend/AI → OTel Collector → Tempo` 중 **Collector 수신·처리·전달 설정**을 작성했다.
[Tempo 배포 기반](../tempo/README.md)은 별도 Application으로 작성했다. Collector 목적지와 Grafana Tempo 데이터소스도 Git으로 연결했다.
Application 계측과 실제 End-to-End Trace 검증은 후속 작업이다.
기존 deprecated 산정용 차트를 재사용하지 않았고 Kafka·새 Operator·Terraform·노드 증설을 추가하지 않았다.

## 무엇을 배포하도록 작성했나?

- Stage/Prod 각각 Kustomize 번들을 수동 `observability-traces` Application에 연결했다. Tempo 준비 전에는 Sync하지 않는다. [배포 순서](../README.md)를 따른다.
- System 노드에 Collector 0.160.0 Deployment 1개, 내부 Service, ServiceMonitor, NetworkPolicy.
- 요청량 100m/256Mi, 메모리 제한 384Mi. 기존 capacity.md의 Collector 후보 요청량과 동일하므로 이중 합산하지 않음.
- 읽기 전용 root filesystem, non-root, API 토큰/ClusterRole 없음.
- `trace-buffer.yaml`은 ConfigMap generator로 제공. hash가 변경되면 Deployment도 재시작.
- health check 13133은 Service에 공개하지 않고 kubelet probe만 사용. 프로세스 생존 확인이며 Tempo 저장 성공을 뜻하지 않음.
- 자체 메트릭 8888을 Prometheus가 30초마다 수집.

## 다른 팀에 제공할 계약

Collector 배포 후 제공할 주소:

```text
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://otel-collector.monitoring.svc.cluster.local:4317
OTEL_EXPORTER_OTLP_TRACES_PROTOCOL=grpc
OTEL_PROPAGATORS=tracecontext,baggage
```

이번 구현은 OTLP **gRPC 4317**이다. HTTP/protobuf 4318이나 `/v1/traces`에 보내는 설정과 혼용하지 않는다.
위 환경변수는 SDK/Agent가 실제 설치되어 지원할 때만 작동한다. 현재 Backend/AI Deployment에 강제로 넣지 않았다.
Stage는 문서상 100% sampling 목표이며 SDK에서 parent-based always-on 등 적용 방식을 해당 팀과 확인한다.
Prod sampling 비율·HA·내부 TLS는 미확정이다. Collector가 이미 버려진 Trace를 복구하지 못한다.

Backend: 요청 Span 생성, AI 호출에 W3C traceparent 전달, 비동기 export.
AI: traceparent 수신 후 동일 Trace에 AI Span 연결, OTLP export.
각 서비스는 실제 `service.name`, 배포 버전, Pod/namespace metadata를 제공해야 한다.
Collector는 `deployment.environment.name=stage|prod`만 환경별로 넣으며 가짜 서비스 이름/Pod 정보를 만들지 않는다.
Prompt/Response 원문·JWT·SQL 파라미터·개인정보는 생성 단계부터 기록하지 않아야 한다.
현재 Collector에 모든 민감정보를 완벽하게 지우는 범용 마스킹은 없다.

## 전송 보호와 한계

memory_limiter(192Mi, spike48Mi) → 환경 속성 → batch(512, 최대1024) → Tempo 순서.
queue는 메모리 내 요청 32개, 소비자 2개, 개별 export timeout 5초, 재시도 최대 경과 15초.
queue 크기가 32MiB라는 의미는 아니다. 메모리 급증/OOM, 재시작 손실을 완전히 막지는 못한다.
Tail sampling, disk queue, service graph, spanmetrics는 추가하지 않았다.
Collector 장애가 앱 요청 실패로 이어지지 않도록 앱도 비동기/유한 재시도를 구현해야 한다.

## 아직 필요한 값과 선행조건

1. **네이티브:** 작성된 Tempo 배포 설정의 실제 System 용량·영속 저장·보존(Stage3일/Prod7일) 검증.
2. **인프라:** 환경별 trace 저장 S3/IRSA(설계상 `monitoring/tempo-sa`, `tempo/*`)와 네트워크 기반.
3. **네이티브:** Tempo 내부 Service와 `app.kubernetes.io/name=tempo` Pod 라벨, 4317 수신 정책 확인.
4. Git이 traces-runtime-<hash> ConfigMap에 tempo.monitoring.svc.cluster.local:4317을 제공한다. Tempo Ready 후 traces Application을 수동 Sync한다.
   주소 변경 시 ConfigMap hash와 Deployment 참조가 함께 바뀌어 Collector가 재시작된다.
5. **Backend/AI:** 계측된 image digest, traceparent 전달과 OTLP export 확인.

현재 export TLS는 클러스터 내부 평문이다. Prod 보안 기준에 따라 인증서·설정을 함께 변경해야 한다.
Collector egress는 monitoring/tempo:4317과 kube-system/CoreDNS:53에 제한했다.
CoreDNS 대신 NodeLocal DNS이면 실제 DNS 경로를 반영해야 한다.
Tempo 수신 정책은 Tempo Application에 포함했다. 실제 CNI에서 양방향 허용·차단을 확인해야 한다.

`application-egress/`는 앱 egress가 이미 격리된 경우 추가할 **별도 opt-in 번들**이다.
Collector 기본 번들에는 포함하지 않았다. 이 정책만 처음 적용하면 앱의 다른 송신이 차단되므로
기존 DNS·DB·AI·외부 API 허용 정책과 함께 검토한다. 앱 egress가 제한되지 않은 상태라면 추가 적용이 필요 없다.

## 검증 결과와 실제 EKS에서 할 일

```sh
kubectl kustomize platform/observability/traces/stage
kubectl kustomize platform/observability/traces/prod
bash scripts/validate-ai-observability.sh
```

기존 Collector 단독 검증 당시 실제 Collector 0.160.0에서:
- 제공 config의 validate 통과.
- read-only/non-root 실행, health check 응답 확인.
- 시험용 OTLP gRPC Span 수신 → 별도 시험용 Collector로 전달 → 동일 Trace ID/환경 속성 확인.
- accepted/sent spans 메트릭 확인.
- 목적지 중단 시 유한 재시도 후 export 실패 메트릭 증가, queue=0 확인.

위 단독 검증의 시험용 목적지는 Tempo가 아니었다. 따라서 해당 결과만으로 Tempo/S3 저장·보존·조회, 실제 Backend→AI 연속 Trace,
EKS DNS/NetworkPolicy, GPU 장치 수집은 검증한 것으로 간주하지 않는다.

실제 EKS: Receiver 수신/거부, Export sent/failed, Queue 크기를 확인하고, Tempo Trace 조회까지 연결한다.
Grafana Explore에서 Tempo 데이터소스로 Trace ID를 조회한다. Loki↔Tempo 링크는 앱 로그의 실제 trace ID 필드가 확정된 뒤 추가한다.

공식 근거: [OTel 내부 메트릭](https://opentelemetry.io/docs/collector/internal-telemetry/),
[Tempo 배포](https://grafana.com/docs/tempo/latest/set-up-for-tracing/setup-tempo/deploy/).

## Collector → Tempo → Grafana 연결 검증 (2026-09-18)

Stage 렌더 결과에서 Collector config와 Grafana datasource 파일을 추출해 고정 이미지로 실행했다.
Docker DNS alias를 tempo.monitoring.svc.cluster.local로 등록해 실제 Git의 주소를 그대로 사용했다.
시험 송신기만 OTLP HTTP를 gRPC로 변환했으며 배포 Collector의 수신 설정은 변경하지 않았다.

- Collector 0.160.0 → Tempo 2.10.8 → Grafana 13.2.2 데이터소스 proxy 조회 성공.
- 시험 Span 이름과 deployment.environment.name=stage 속성을 같은 조회 응답에서 확인.
- 파일 기반 데이터소스 4개(Prometheus, Alertmanager, Loki, Tempo) 등록 확인.
- 존재하지 않는 Trace ID 조회는 404로 응답.
- 두 환경의 전체 validate-k8s.sh 통과. 주소 ConfigMap hash 참조와 Tempo 데이터소스 URL도 검사한다.

이번 연결 시험에서 Tempo 저장소만 임시 local backend로 바꿨다. AWS 자격 증명은 사용하지 않았다.
이 결과는 AWS S3/IRSA, EKS DNS/NetworkPolicy, Prod 실부하, 실제 앱 계측의 성공을 뜻하지 않는다.
기존 S3 호환 저장소 block 검증은 [Tempo 검증 기록](../tempo/README.md)을 참조한다.

## 실제 배포 순서와 완료 기준

1. 나중에 S3·IRSA·승인된 egress 값을 채우고 해당 환경의 Tempo Application을 수동 Sync한다.
2. Tempo Ready와 저장소 접근을 확인한 뒤 traces Application을 수동 Sync한다.
3. metrics Application을 수동 Sync해 Grafana 데이터소스 파일을 반영한다. 설정 checksum 변경으로 Grafana가 재시작한다.
4. Grafana Explore → Tempo → Trace ID 조회에서 시험 Span을 확인한다. datasource 등록 자체는 저장 성공이 아니다.
5. 실제 Backend·AI 계측 이후 같은 Trace ID에 두 서비스 Span이 연결되는지 검증한다.

metrics를 먼저 Sync해도 기존 메트릭·로그 데이터소스는 유지된다. Tempo 준비 전에는 Tempo 조회만 실패할 수 있다.
Stage에서 검증한 후 Prod에도 같은 순서를 적용한다. merge만으로 자동 배포되지는 않는다.
로그 trace ID 필드가 합의되지 않아 Loki derivedFields/Trace-to-logs 링크는 추가하지 않았다.
