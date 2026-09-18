# 팀원 Backend 모니터링 초안 선별 반영

원본: origin/feat/monitoring의 659a6c2, k8s/base/monitoring/configmaps/grafana-dashboards/janginmall-cpu-mem-dashboard.yaml.
대조 대상: 로컬 Backend HEAD fdb3650의 build.gradle, application.yml, PermitAllPaths.java 및 infra Backend Rollout.
Backend 저장소는 수정하지 않았다. 이 확인은 실제 배포 이미지에서 메트릭 값을 수신했다는 뜻이 아니다.

## 채택

- 원본 대시보드의 Pod CPU/메모리, HTTP 요청량/오류율, JVM heap/GC/thread, HikariCP 패널을 재사용했다.
- 평균 HTTP 응답 시간을 포함해 총 9개 패널이다. 네임스페이스 app, Backend Pod 선택 변수, Prometheus uid를 현재 구성에 맞췄다.
- heap/connection 등 합산 패널은 선택된 Pod들의 집계다. Pod 하나를 선택해서 문제 인스턴스를 확인할 수 있다.
- p95/p99는 histogram 활성화가 확인되지 않아 제외했다. 평균은 지연의 꼬리 분포를 대신하지 않으며 SSE 장기 연결은 별도 해석이 필요하다.
- 기존 ServiceMonitor 의도는 PodMonitor로 구현했다. management:9090, /actuator/prometheus, 30초 주기이며 Stable/Preview를 모두 선택한다.
- revision 라벨은 Rollouts hash다. 현재 active/preview 역할은 Rollout 상태와 대조한다.
- Prometheus에서만 Backend 9090으로 들어갈 수 있도록 ingress 허용 규칙을 추가했다. 이 규칙 하나가 default-deny를 만드는 것은 아니다.

## 제외

- bulk_order, settlement_batch, inventory_sync, 외부 Modal 등 이 대조에서 제공 계약이 확인되지 않은 지표.
- 일반 postgres exporter 이름의 pg_* 지표: CNPG 실제 노출 지표와 대조하기 전에는 사용하지 않는다.
- S3의 Prometheus aws_* 지표: 우리 방향은 CloudWatch 직접 조회다.
- 노드 패널: 기존 기본 Kubernetes 대시보드가 있으며 EKS nodegroup 라벨 노출 계약도 확인이 필요하다.
- 동료 초안의 경보 임계값과 Discord 라우팅은 그대로 채택하지 않았다. 별도 [팀 경보 구성](../alerts/README.md)에 현재 코드의 지표와 환경별 경계를 반영했다. 실제 채널 연결은 남아 있다.
- DCGM 제외 주석: 사용자와 기존 설계의 GPU 관측 범위를 변경하는 근거로 사용하지 않는다.

## 파일 공급

대시보드 JSON은 metrics Application의 observability-assets chart가 ConfigMap으로 공급한다. 별도 복사본과 `--set-file` 입력은 필요 없다.
Grafana는 ConfigMap을 디렉터리로 마운트하고 kubelet 파일 갱신 후 30초 polling으로 읽는다. JSON 변경에 재시작은 필요 없고, datasource/provider 변경은 기존 checksum에 따라 재시작한다.
이 디렉터리의 PodMonitor/NetworkPolicy는 observability-targets Application에 연결했다. [최초 수동 배포 순서](../README.md)를 따른다.

## 검증과 남은 일

Stage·Prod Helm lint/render, PodMonitor 계약 검사, Prometheus promtool의 11개 패널 조회식 구문 검사를 통과했다.
실제 EKS에서 Target UP, HTTP/JVM/Hikari 계열 존재 여부, Stable/Preview 수집, Pod별 필터링과 실제 값 대조가 필요하다.
지표 미존재를 0 또는 정상 상태로 간주하지 않는다. 기본 Backend 경보는 alerts/에 작성했다. histogram, 업무별 메트릭 및 p95 경보는 실제 계약을 확인한 뒤 확장한다.
로컬 Grafana 13.2.2의 HTTP API에서 채택 대시보드와 패널 9개가 파일 공급으로 로딩되는 것을 확인했다. 실제 Backend 메트릭 데이터와 시각적 부하 검증은 포함하지 않는다.
