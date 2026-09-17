# GPU·AI에서 네이티브 담당자가 구현한 범위

## 설계와 현재 코드의 차이

근거: [노션 관측성 설계 4.2/4.4/5.5](https://app.notion.com/p/c760842d874f83758b7b81f9766b276e).
설계의 목표는 AI API `:8000/metrics`, GPU DCGM, Backend→AI Trace 연결이다.
2026-09-17 확인한 로컬 `GenAI/chat_bot/requirements.txt`·`app/main.py`에는 Prometheus/OTel 계측과 `/metrics`가 없다.
`page_generation`에는 README만 확인했다. 따라서 두 실제 배포 이미지 모두 계측됐다고 판단하지 않는다.
Backend/AI 저장소는 수정하지 않았다. 애플리케이션 메트릭/Trace 생성은 해당 팀 책임이다.

## 지금 작성한 것

- NVIDIA 공식 chart **4.8.3**, image **4.6.0-4.8.3-distroless**의 DCGM Exporter.
- `monitoring` namespace에 DaemonSet, `workload-type=gpu` Linux 노드마다 1개.
- `nvidia.com/gpu=true:NoSchedule` 허용: L40S와 T4 모두 같은 설정을 사용한다.
- GPU 리소스를 예약하지 않는다. AI에 할당할 GPU를 모니터링이 점유하면 안 된다.
- 100m/128Mi 요청, 메모리 제한 512Mi. GPU 노드 비용이며 System 예산에는 더하지 않는다.
- kubelet pod-resources 소켓과 NVIDIA runtime 장치를 사용. hostNetwork/hostPID/API 토큰/ClusterRole 없음.
- profiling 수집을 제외해 SYS_ADMIN을 주지 않는다. L40S/T4의 드라이버·runtime에서 기본 지표 조회 가능 여부는 EKS에서 확인한다.
- `release=metrics` ServiceMonitor, 9400 `/metrics`, 30초 수집. Prometheus만 접근하도록 NetworkPolicy 작성.
- 차트는 customMetrics용 ConfigMap 1개 get Role도 생성한다. API 토큰은 마운트하지 않으며 파일 마운트로 제공한다.
- Node가 0개이면 Exporter도 0개다. 자동 노드 생성이나 GPU 드라이버 설치 기능을 추가한 것은 아니다.

## 대시보드 8개 패널

GPU 사용률, GPU 메모리 사용률, 온도, 전력, 마지막 XID 오류 코드,
AI Pod Ready, AI Pod Pending, AI 컨테이너 15분 재시작 수.
GPU 수치는 DCGM에서, Pod 상태는 기존 kube-state-metrics에서 가져온다.
노드/UUID/modelName별로 구분한다. 지원하지 않는 DCGM sentinel 값은 제외하며 없는 값을 0으로 채우지 않는다.
XID는 마지막 오류 **코드**다. 오류 발생 **횟수**나 오류율로 해석하지 않는다.
AI Pod 필터는 `ai-sglang-*`/`ai-ollama-*`다. 벡터DB를 AI inference Pod에 합산하지 않는다.
GPU 사용률만으로 요청 성공/실패·추론 p95·모델 로딩 시간을 알 수는 없다.

Grafana 파일 제공 방식에 연결했으며 추가 sidecar가 없다. metrics Application의 assets source가 GPU JSON을 ConfigMap으로 공급한다. 디렉터리 마운트와 30초 polling으로 갱신하며 JSON 변경에 재시작은 필요 없다.

## AI API 메트릭은 준비만 한 상태

`../ai-metrics`는 별도 수동 Application으로 연결했다. GPU 또는 기본 workload Sync만으로 적용되지 않는다.
실제 AI 이미지가 `http`라는 컨테이너 포트(8000)의 `/metrics`를 제공한 뒤 적용한다.
AI-SGLang/Ollama 양쪽 Pod를 대상으로 하며 엔진 내부 포트 11434는 열지 않는다.
NetworkPolicy는 HTTP 경로를 구분하지 않아 Prometheus에 8000 포트 전체를 허용한다.
AI 요청/지연/오류 metric 이름과 histogram bucket은 AI팀이 제공한 실제 출력과 대조한 후 대시보드를 추가한다.

## 실행과 검증

```sh
bash scripts/validate-ai-observability.sh
bash scripts/validate-observability.sh
```

observability-gpu Application이 공식 chart와 `policies/`를 함께 소유한다. release `dcgm-exporter`, namespace `monitoring`을 유지한다. Prometheus Operator CRD와 NVIDIA runtime 준비 후 [수동 Sync](../README.md)한다.

로컬 확인: 공식 Helm lint/render, Stage/Prod Collector Kustomize, PromQL 8개 문법,
Grafana 13.2.2 브라우저에서 상단/하단 8개 패널 렌더링과 No data 상태 확인.
NVIDIA GPU가 없는 Mac이므로 DCGM 장치 수집 자체는 검증하지 않았다.

배포 전 확인:
- [ ] GPU AMI/드라이버 버전과 DCGM 4.6.0 호환성, NVIDIA container runtime/device plugin 준비.
- [ ] GPU를 예약하지 않는 Exporter에서도 `NVIDIA_VISIBLE_DEVICES=all`로 장치가 보이는 runtime 설정.
- [ ] pod-resources 소켓 `/var/lib/kubelet/pod-resources`와 접근 권한.
- [ ] L40S/T4에서 GPU 수치가 실제 nvidia-smi 값과 맞는지, exporter workload label 구분.
- [ ] GPU가 없는 정상 Stage 상태와 수집 장애를 구분. 무조건 `absent()` 오류 알림을 만들지 않음.
- [ ] EKS NetworkPolicy 실제 차단/허용 및 Prometheus Target UP.

공식 근거: [NVIDIA chart](https://github.com/NVIDIA/dcgm-exporter/tree/main/deployment),
[DCGM 릴리스 노트](https://docs.nvidia.com/datacenter/dcgm/latest/release-notes/dcgm-exporter.html).
