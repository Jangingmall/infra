# 산정 전용 Helm 입력과 결과

배포용 설정이 아니다. Argo CD에 등록하지 않는다. 임시 S3 버킷 이름, 미완성 pipeline 및 저장소 설정이 있다.

- charts.yaml: 공식 저장소에서 조회한 버전. 운영 채택 승인이 아니다.
- prometheus/loki/tempo/alloy/otel.yaml: 용량 비교용 requests 및 topology 후보.
- controller-requests.yaml: 당시 미지정 Controller requests를 메우기 위한 비교 제안. 현재 CNPG/Rollouts 실제 values에는 요청량을 반영했고 Rollouts Dashboard는 비활성화했다. 이 비교 파일을 배포하지 않는다.
- rendered-containers.csv: 고정 차트 렌더링에서 추출한 상시 컨테이너/일시 Job 목록. DaemonSet은 System 노드 2개분만 포함.
- Prometheus/Alertmanager의 reloader는 Operator가 생성하므로 Operator 인자에서 별도로 산정했다.
- Tempo chart의 deprecation 때문에 이 입력은 실제 배포 버전으로 사용하지 않는다.

재현: charts.yaml의 각 repo/chart/version으로 helm pull 후 `helm template <id> <chart-dir> -n monitoring -f <id>.yaml` 실행.
실제 Helm lint/render 통과는 데이터 수집·저장 동작 또는 용량의 충분성을 입증하지 않는다.
