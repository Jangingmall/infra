# Tempo 배포 기반

요청별 처리 기록을 저장하는 Tempo를 Stage·Prod에 배포할 **코드**다. 실제 EKS에 적용하지 않았다.
Collector의 목적지 ConfigMap과 Grafana 데이터소스, Backend·AI 계측은 다음 작업이다.

## 배포 구조와 버전

```text
argocd/applications/<env>/tempo.yaml (수동 Sync)
 ├─ grafana-community/tempo 2.4.0 → Tempo 2.10.8 StatefulSet 1개
 │   ├─ tempo-sa (IRSA)
 │   ├─ ClusterIP Service, ServiceMonitor
 │   └─ gp3-monitoring WAL PVC 10Gi
 └─ 기존 observability-assets chart → NetworkPolicy, 준비 시 tempo-runtime ConfigMap
```

폐기 표시가 있는 기존 grafana/tempo 1.24.4는 sizing/의 과거 비교 자료에만 남긴다.
단일 프로세스 구성을 유지하기 위해 커뮤니티 차트 2.4.0과 이미지 2.10.8을 함께 고정했다.
3.x로의 전환은 저장·수집 구조 변경 검토가 필요하므로 자동으로 따라가지 않는다.
이는 작은 프로젝트용 초기 구성이며 고가용성·대량 유입을 보장하지 않는다. 버전 고정은 보안 업데이트 점검을 대체하지 않는다.

| 항목 | Stage | Prod |
|---|---|---|
| S3 보존 기간 | 72시간 | 168시간 |
| 환경 버킷 내 경로 | tempo/staging/ | tempo/prod/ |
| ServiceAccount | monitoring/tempo-sa | monitoring/tempo-sa |
| 이미지 | grafana/tempo:2.10.8 | 동일 |
| requests | 250m / 768Mi | 동일 |
| limits | CPU 1 / 메모리 1536Mi | 동일 |
| WAL PVC | gp3-monitoring, 10Gi | 동일 |

보존 기간은 Tempo compactor 설정이다. 만료 시간 직후 즉시 삭제를 보장하지 않으며, S3 버전 관리·lifecycle도 별도 확인한다.
Loki와 같은 버킷이면 tempo/* 전용 권한과 prefix별 lifecycle을 사용한다. 버킷 전체에 Loki 보존 기간을 일괄 적용하지 않는다.
WAL은 S3로 전송하기 전의 기록이다. PVC 10Gi는 전체 3일/7일 데이터를 담는 용량이 아니며 유입량·S3 장애 기간에 맞춰 검증할 초기 제안이다.
EBS와 PVC는 보존한다. 자동 prune/PVC 자동 삭제를 끄고 StatefulSet에 삭제 확인 보호를 넣었다. Retain은 백업이나 무손실 보장이 아니다.

## 자원과 배치

- workload-type=system만 지정한다. medium 1대 + large 1대 중 실제 requests와 PVC AZ에 맞게 배치한다.
- 다른 저장 Pod와 hostname을 나누도록 soft anti-affinity를 사용한다. 서로 다른 노드 배치를 보장하지 않는다.
- 기존 capacity.md의 Tempo 250m/768Mi 예산을 실제 배포값으로 사용하므로 후보 합계에 다시 더하지 않는다.
- 차트 기본 1Gi memory ballast를 0으로 바꾸고 GOMEMLIMIT=1152MiB를 설정했다. GOMEMLIMIT은 Go 런타임 목표이며 컨테이너 전체 메모리의 절대 상한이 아니다.
- 쿼리 동시 실행 2개, 검색 작업 동시 실행 2개, tenant별 대기 쿼리 32개로 제한했다. Trace ID 조회는 8개로 분할하고 동시에 2개씩 실행한다. 기본 분할 50개를 유지하면 대기열 32개를 넘겨 한 번의 조회도 HTTP 429가 될 수 있다.
- 별도 tempo-query, metrics-generator, Kafka, Operator를 추가하지 않는다.
- 단일 Pod이므로 재시작/노드 장애 중 수집·조회가 중단될 수 있다. Collector의 메모리 큐만으로 장시간 장애를 보전하지 못한다.

## 배포 전에 인프라에서 받을 값

`tempo/runtime/stage.yaml`과 `tempo/runtime/prod.yaml`에 각 환경의 값을 넣는다.
공통 `observability/runtime/`의 Loki용 ServiceAccount 설정을 가져오지 않는다.

| 키 | 준비 내용 |
|---|---|
| tempoBucket | 실제 환경의 S3 로그 버킷 이름 |
| serviceAccount.annotations.eks.amazonaws.com/role-arn | tempo-sa 전용 IRSA Role ARN |
| tempoEgressCidrs | 인프라·보안팀이 확인한 S3와 regional STS 목적지 CIDR 목록 |

셋 중 일부만 입력하면 Helm 렌더링이 실패한다. 모두 비어 있으면 CI용 구조는 렌더링하지만 tempo-runtime은 만들지 않는다.
이때 수동 Sync를 잘못 실행해도 필수 ConfigMap이 없어 Tempo 컨테이너는 시작하지 않는다. 준비 전 Sync하지 않는다.
모든 값이 있다고 IAM/라우팅이 검증된 것은 아니다. 실제 권한과 통신을 확인해야 한다.
runtime 값 제거는 자동 prune을 켜지 않았으므로 기존 ConfigMap을 자동 삭제하지 않는다. 운영 중 중지/권한 회수는 별도 절차로 수행한다.

IRSA 요구사항:

- 해당 EKS OIDC provider, audience sts.amazonaws.com, subject system:serviceaccount:monitoring:tempo-sa.
- 버킷 ListBucket 권한은 해당 tempo 환경 prefix 범위, GetBucketLocation은 버킷에 부여.
- 해당 prefix의 GetObject/PutObject/DeleteObject 및 SDK가 사용하는 multipart 작업 권한 확인.
- SSE-KMS를 사용하면 해당 키의 GenerateDataKey/Decrypt와 키 정책 허용 확인.
- static AWS Access Key나 Pod Identity를 사용하지 않는다. IRSA 미연결 시 EC2 metadata 자격 증명으로 우회하지 않는다.
- Kubernetes API 토큰 자동 마운트는 껐다. EKS IRSA webhook이 별도의 WebIdentity token volume과 AWS_ROLE_ARN/AWS_WEB_IDENTITY_TOKEN_FILE을 주입하는지 Pod에서 확인한다.
- 현재 AWS 리전/endpoint는 ap-northeast-2다. 다른 리전으로 변경 시 S3·STS·IAM·네트워크를 함께 검토한다.

## 통신 정책

| 출발지 | 목적지 | 허용 |
|---|---|---|
| monitoring/otel-collector | Tempo | TCP 4317, OTLP gRPC |
| monitoring/Grafana, Prometheus | Tempo | TCP 3200, 조회·메트릭 |
| Tempo 자신 | 동일 release Tempo | TCP 9095, TCP/UDP 7946 내부 통신 |
| Tempo | kube-system/CoreDNS | TCP/UDP 53 |
| Tempo | 인계받은 S3·STS CIDR | TCP 443 |

Tempo는 자체 로그인 계층이 없으므로 Ingress·LoadBalancer로 공개하지 않는다. Backend·AI가 Tempo에 직접 보내는 경로도 열지 않았다.
고정 차트가 Service/Pod에 legacy 포트 이름을 일부 생성하지만, 실행 설정에서 OTLP gRPC만 켰고 NetworkPolicy에서도 다른 수신을 차단한다.
CoreDNS가 아닌 NodeLocal DNS를 사용하면 정책 수정이 필요하다. VPC CNI 정책 강제 적용과 노드/Pod 보안 그룹도 확인한다.
다른 NetworkPolicy의 허용 규칙은 합쳐진다. monitoring 전체를 허용하는 기존 정책이 있다면 이 정책 하나로 차단된다고 판단하지 않는다.
표준 NetworkPolicy는 FQDN이나 AWS Prefix List ID를 직접 받지 않는다. S3 IP 범위 변경을 누가 어떻게 갱신할지도 인프라에서 정해야 한다.
0.0.0.0/0, ::/0 허용을 임시 해결책으로 넣지 않는다. IRSA 토큰 교환용 STS 경로가 빠지면 S3 권한이 있어도 실패한다.

## 로컬 검증

```bash
ruby scripts/render-observability.rb stage /tmp/tempo-stage tempo
ruby scripts/validate-tempo.rb stage /tmp/tempo-stage
ruby scripts/render-observability.rb prod /tmp/tempo-prod tempo
ruby scripts/validate-tempo.rb prod /tmp/tempo-prod
bash scripts/validate-k8s.sh
```

기존 CI가 두 환경의 실제 Argo CD 소스를 렌더링하고 자원 소유권·Project 권한을 검사한다.
Tempo 검증은 버전·보존·환경 경로·IRSA 구조·WAL·수신 제한과 빈/완성/누락/과도한 허용 runtime 입력을 검사한다.
AWS·클러스터 없이 수행하는 검증이며 실제 CIDR·ARN의 운영 권한을 증명하지 않는다.

### 이번 로컬 검증 결과

- Stage·Prod의 실제 Argo CD sources 각각 7개 리소스 렌더링, AppProject 권한·중복 소유 검사 통과.
- 두 환경의 S3/IRSA 구조, 보존 기간·prefix, 내부 통신, WAL, 자원 예산, runtime 준비 조건 검사 통과.
- `bash scripts/validate-k8s.sh` 전체 통과. 기존 Backend 용량 경고는 유지된다.
- 고정 Tempo 2.10.8 바이너리의 `-config.verify=true`로 두 환경 설정 검사 통과.
- 같은 바이너리를 non-root/read-only, 1536Mi 메모리 제한으로 로컬 실행해 `/ready` 응답 확인.
- 시험 Collector에서 OTLP gRPC Span 전달 → Trace ID로 HTTP 조회 → 로컬 S3 호환 저장소의 tempo/staging/ block 생성 → Tempo 재시작 후 `mode=blocks` 조회 통과.
- 실행 검증에서 대기열 32개와 기본 조회 분할 50개의 충돌로 HTTP 429를 발견했다. 분할 8개/동시 2개로 수정했고, 잘못된 조합을 거부하는 회귀 검사를 추가했다.
- 로컬 시험은 저장소 endpoint와 인증만 시험용 MinIO로 교체했다. 실제 AWS IRSA·KMS·EBS·CNI, 3일/7일 경과 삭제, 부하·장애 내구성, 실제 Backend→AI 연동을 검증한 결과는 아니다.
- 임시 검증 컨테이너와 Docker 네트워크는 종료 후 제거했다. 실제 클러스터 변경은 없다.

## 실제 Stage 배포·확인 순서

1. main merge와 올바른 kubectl context 확인. monitoring namespace, EBS CSI, gp3-monitoring, Prometheus CRD가 먼저 준비되어야 한다.
2. 환경 runtime 값과 IAM·S3/KMS·네트워크·노드별 requests/allocatable·EBS AZ를 확인한다.
3. `argocd app diff stage-observability-tempo`에서 예상 리소스와 실제 값을 검토한다.
4. `argocd app sync stage-observability-tempo` 후 `argocd app wait stage-observability-tempo --sync --health --timeout 600`으로 확인한다.
5. `kubectl -n monitoring get pods,pvc -l app.kubernetes.io/instance=tempo`와 `kubectl -n monitoring get pvc storage-tempo-0`에서 Pod Ready/PVC Bound 확인.
6. `kubectl -n monitoring get pod tempo-0 -o yaml`에서 IRSA 주입 확인. 토큰 파일 내용은 출력하지 않는다.
7. `kubectl -n monitoring port-forward service/tempo 3200:3200` 후 `curl -fsS http://127.0.0.1:3200/ready` 확인. 이것만으로 추적 저장 성공을 선언하지 않는다.
8. traces와 metrics Application 수동 Sync 후 시험 Trace ID 하나를 보내 API 조회, S3 환경 prefix 내 block 생성, 재시작 후 저장 데이터 조회를 확인한다.
9. 허용된 Collector/Grafana/Prometheus Pod의 통신과 허용되지 않은 Pod의 거부를 각각 확인한다. port-forward는 NetworkPolicy 검증을 대체하지 않는다.
10. 유입·검색 부하에서 메모리, OOM, CPU throttling, WAL 사용량, S3 실패·재시도를 관측한다. Stage 보존 기간 경과 후 삭제 정책을 확인한다.
11. Stage 증거 확인 후 Prod의 고유 ARN·버킷·CIDR과 7일 보존 설정으로 동일 절차를 수행한다.

Collector의 traces-runtime과 Grafana Tempo 데이터소스를 같은 브랜치에서 연결했다. [연결 검증 및 배포 순서](../traces/README.md)를 따른다. 테스트용 Span 성공과 실제 Backend→AI 추적 성공은 구분한다.

참고: [커뮤니티 차트](https://github.com/grafana-community/helm-charts/tree/tempo-2.4.0/charts/tempo), [Tempo 2.10 설정](https://grafana.com/docs/tempo/v2.10.x/configuration/).
