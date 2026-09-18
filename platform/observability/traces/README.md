# Trace 수신 기반: 네이티브 단독 구현 범위

## 현재 상태

[노션 9장 설계](https://app.notion.com/p/c760842d874f83758b7b81f9766b276e)에 맞춰
`Backend/AI → OTel Collector → Tempo` 중 **Collector 수신·처리·전달 설정**을 작성했다.
Tempo 저장소, Grafana Tempo 데이터소스, Application 계측, 실제 End-to-End Trace는 미구현/미연결이다.
기존 deprecated Tempo chart를 배포 경로에 재사용하지 않았다. 현재 Tempo 배포 방식과 전체 System 용량을
먼저 결정해야 한다. 이 작업에서 Kafka·새 Operator·Terraform·노드 증설을 추가하지 않았다.

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

1. **네이티브:** Tempo의 실제 배포 방식·System 예산·영속 저장·보존(Stage3일/Prod7일) 구현.
2. **인프라:** 환경별 trace 저장 S3/IRSA(설계상 `monitoring/tempo-sa`, `tempo/*`)와 네트워크 기반.
3. **네이티브:** Tempo 내부 Service와 `app.kubernetes.io/name=tempo` Pod 라벨, 4317 수신 정책 확인.
4. 위 준비 후 `monitoring/traces-runtime` ConfigMap에 `TEMPO_OTLP_ENDPOINT`를 실제 `호스트:4317`로 제공.
   이 ConfigMap은 의도적으로 생성하지 않았다. 없는 경우 Collector Pod는 시작하지 않는다.
5. **Backend/AI:** 계측된 image digest, traceparent 전달과 OTLP export 확인.

현재 export TLS는 클러스터 내부 평문이다. Prod 보안 기준에 따라 인증서·설정을 함께 변경해야 한다.
Collector egress는 monitoring/tempo:4317과 kube-system/CoreDNS:53에 제한했다.
CoreDNS 대신 NodeLocal DNS이면 실제 DNS 경로를 반영해야 한다.
Tempo 수신 정책은 Tempo 배포 시 함께 작성한다.

`application-egress/`는 앱 egress가 이미 격리된 경우 추가할 **별도 opt-in 번들**이다.
Collector 기본 번들에는 포함하지 않았다. 이 정책만 처음 적용하면 앱의 다른 송신이 차단되므로
기존 DNS·DB·AI·외부 API 허용 정책과 함께 검토한다. 앱 egress가 제한되지 않은 상태라면 추가 적용이 필요 없다.

## 검증 결과와 실제 EKS에서 할 일

```sh
kubectl kustomize platform/observability/traces/stage
kubectl kustomize platform/observability/traces/prod
bash scripts/validate-ai-observability.sh
```

로컬 실제 Collector 0.160.0에서:
- 제공 config의 validate 통과.
- read-only/non-root 실행, health check 응답 확인.
- 시험용 OTLP gRPC Span 수신 → 별도 시험용 Collector로 전달 → 동일 Trace ID/환경 속성 확인.
- accepted/sent spans 메트릭 확인.
- 목적지 중단 시 유한 재시도 후 export 실패 메트릭 증가, queue=0 확인.

시험용 목적지는 Tempo가 아니다. 따라서 Tempo/S3 저장·보존·조회, 실제 Backend→AI 연속 Trace,
EKS DNS/NetworkPolicy, GPU 장치 수집은 검증한 것으로 간주하지 않는다.

실제 EKS: Receiver 수신/거부, Export sent/failed, Queue 크기를 확인하고, Tempo Trace 조회까지 연결한다.
그 후 Grafana Loki↔Tempo 링크를 추가한다. 존재하지 않는 Tempo 데이터소스를 미리 연결하지 않는다.

공식 근거: [OTel 내부 메트릭](https://opentelemetry.io/docs/collector/internal-telemetry/),
[Tempo 배포](https://grafana.com/docs/tempo/latest/set-up-for-tracing/setup-tempo/deploy/).
