# 기존 ALB 연결과 NetworkPolicy

## 현재 구현 상태

Terraform 소유 ALB/Target Group에 **TargetGroupBinding(TGB)**으로 Backend를 연결한다.
이전 Ingress 초안은 교체했다. ALB·리스너·TLS·WAF·DNS·SG를 네이티브에서 새로 생성하지 않는다.
Stage·Prod 별도 Application은 수동 Sync이며 실제 AWS/EKS 적용은 하지 않았다.

```text
사용자 → 인프라가 관리하는 ALB/TG → TGB → backend-active:8080 → Backend
상세페이지 ai-sglang → backend-active:8080/internal/generations/complete/multipart
Prometheus → Backend:9090
```

- 로컬 chart는 TGB/backend + NetworkPolicy/backend-entrypoint만 생성한다.
- Backend base에는 ai-sglang callback ingress가 있다. ai-ollama와 무관한 Pod의 callback은 허용하지 않는다.
- TGB는 active Service만 참조하고 Pod IP를 직접 고정하지 않는다. Preview는 내부 Service로 검증한다.
- SG는 Terraform 소유이므로 TGB networking 필드를 생략했다.
- TGB 삭제는 ALB 삭제와 다르지만 대상 등록 해제로 서비스가 중단될 수 있어 Prune/Delete 확인을 요구한다.
- 모든 NetworkPolicy 허용은 합산된다. IP CIDR로 ALB 신원을 보증하지 않으므로 ALB SG→Backend 8080 제한도 필요하다.

## 배포 전 환경 값

platform/networking/stage.yaml 또는 prod.yaml에 세 값을 입력하고 enabled: true로 전환한다.
기본 false에서는 chart 리소스가 없으며 true인데 값이 빠지면 렌더링을 거부한다.

| 값 | 의미 |
| --- | --- |
| targetGroupARN | 인프라가 생성한 해당 환경의 IP Target Group ARN |
| vpcID | Target Group과 Backend Pod가 속하는 환경 VPC ID |
| albSourceCidrs | 실제 ALB→Pod 패킷 출발지인 ALB subnet IPv4 CIDR 목록 |

ALB subnet ID·도메인·ACM/WAF/SG ARN은 이 chart 입력에서 제거했다. 인프라 코드에서 관리한다.
AWS Load Balancer Controller, IRSA, elbv2.k8s.aws/v1beta1 CRD가 선행되어야 한다. TGB도 Controller가 필요하다.
AppProject에는 Ingress 대신 TargetGroupBinding만 허용했다.
Terraform 담당자는 HTTPS listener/WAF/DNS, target-type=ip, HTTP8080 /healthz, SG를 확인한다.
기존 모듈의 health interval30/timeout5/healthy2/unhealthy3, deregistration30과 Rollout scaleDownDelay60을 실제 환경에서 대조한다.
이 저장소가 ALB를 인수하거나 생성하지 않으며 실제 ARN 존재/AZ/SG 연결은 로컬 검사로 증명하지 못한다.

## SGLang 실행 계약

| 설정 | 반영 내용 |
| --- | --- |
| startup/liveness | /health: API 생존 확인 |
| readiness | /health/ready: text/image 서버 준비 확인; 각각 2초 확인을 고려해 timeout6초 |
| BACKEND_URL | http://backend-active.app.svc.cluster.local:8080/internal/generations/complete/multipart |
| Backend의 AI 주소 | AI_CONTENT_URL=ai-sglang:8000, AI_CHAT_BOT_URL=ai-ollama:8000의 내부 DNS |
| callback ingress | ai namespace + ai-sglang 라벨 → Backend8080; Stage·Prod workload에 포함 |
| callback egress | 같은 목적지 8080, 대기 AI egress 번들에 포함; 아직 전체 번들 비활성 |
| 토큰 전달 | Parameter Store → CSI 파일 → 시작 스크립트 환경변수 → 기존 이미지 entrypoint |

현재 이미지에 *_FILE 지원이 없어 infra의 start.sh가 두 파일을 읽고 /usr/local/bin/detail-page-ai-entrypoint를 exec한다.
실제 토큰을 YAML/명령 인자로 쓰거나 출력하지 않으며 Kubernetes Secret으로 복사하지 않는다.
빈 파일/누락이면 시작을 중단한다. CSI 회전만으로 이미 실행 중인 환경변수는 바뀌지 않으므로 토큰 교체 후 Pod 재시작이 필요하다.
ConfigMap hash 변경은 자동으로 Pod template을 변경한다.

제안 SSM 경로(실제 등록 안 함):

| 환경 접두사 | 경로 | 소비자 |
| --- | --- | --- |
| /staging 또는 /prod | /backend/backend-auth-token | Backend configtree BACKEND_AUTH_TOKEN + SGLang callback 인증 |
| /staging 또는 /prod | /ai/internal-auth-token | SGLang AI_INTERNAL_AUTH_TOKEN |

ai-worker-sa IRSA에 필요한 두 파라미터 조회 권한을, backend-sa에는 callback 토큰 조회 권한을 인계해야 한다.
ai-worker-sa는 현재 두 AI가 공유하므로 IRSA 권한 역시 공유된다. 파일 마운트는 SGLang에만 추가했지만 IAM 격리를 의미하지 않는다.
토큰은 상호 비교되는 실제 앱 값과 맞아야 한다. 빈 토큰으로 인증을 끄는 우회는 하지 않는다.

**앱 연동은 미완료다.** 현재 Backend는 /ai/products를 호출하고 Authorization을 설정하지 않는다.
현재 page_generation은 다른 내부 API와 토큰 인증을 사용한다. 두 팀이 endpoint·요청/응답 DTO·인증을 맞춘 이미지가 필요하다.
SGLang image digest, 모델/PVC/SQLite/asset 영속 경로, CPU·메모리 예산과 모델 다운로드 경로도 실제 이미지 기준으로 확정해야 한다.
이번 변경은 이를 검증 완료로 취급하지 않는다. Backend·AI 소스와 Terraform은 수정하지 않았다.

## NetworkPolicy 상태

| 범위 | 현재 상태 |
| --- | --- |
| ALB→Backend8080 / Prometheus→Backend9090 | TGB chart에 구현, 실제 환경 값 및 수동 Sync 대기 |
| SGLang→Backend8080 | 수신은 ALB·메트릭과 동일한 gated 정책에 반영, 발신은 대기 egress 번들에 반영 |
| Ollama→Backend / AI→업무 DB | 별도 허용 없음; 선택된 수신 정책 기준 차단 |
| Backend→DB5432/두 AI8000, DNS53, Collector4317 | 공통 규칙 존재, Backend 전체 egress는 외부 예외 준비 전 비활성 |
| Ollama→벡터DB5432 | 기존 정책 유지 |
| DB API·S3·STS egress | 실제 API 범위 및 백업 호출 주체 확인 뒤 추가 필요 |
| 앱 외부 API·모델 다운로드 egress | 아래 조사 목록은 확보, 승인 목적지/CIDR/통제 방식 미확정 |
| 관측성·Argo | 기존 수집/Tempo 제한 유지. 전체 egress 및 넓은 제어 포트 축소는 남음 |

Backend callback 예외는 ALB·Prometheus 허용과 같은 backend-entrypoint 정책에서 활성화한다.
networking 비활성 상태의 workload만으로 Backend ingress를 새로 격리하지 않는다. 기존 관측성 정책도 ingress 격리를 유발하므로 실제 ALB 예외와 적용 순서를 함께 확인한다.
NetworkPolicy는 /internal 경로별 제한이 불가능하다. 허용된 SGLang이라도 Backend의 애플리케이션 인증은 별도로 필요하다.

외부 목적지를 모른 채 0.0.0.0/0:443을 넣거나 일회성 DNS IP를 고정하지 않는다.
SSM/KMS/Endpoint/모델 경로 값이 준비되면 해당 주체의 정책에만 추가한다. 지금은 외부 egress 완성으로 표시하지 않는다.

## 검증

```sh
ruby scripts/validate-networking.rb
bash scripts/validate-k8s.sh
```

Stage·Prod TGB/active Service 연결, 자동 ALB 생성 리소스 없음, 필수 값 누락 거부, 수신 허용·차단 16개 시나리오,
SGLang 전용 callback egress, probe·주소·CSI/configtree의 환경별 동일 callback 토큰 연결을 확인한다.
로컬 컨테이너에서 non-root/read-only/network-none으로 start.sh를 실행해 정상 전달·리터럴 처리·빈 토큰/누락 거부를 확인했다.
GPU 이미지, AWS IRSA/SSM, Target 등록, 실제 CNI 패킷 집행, Backend↔AI API 동작은 이번 로컬 검증에 포함되지 않는다.

## EKS 검증 순서

1. 인프라 ALB/TG와 Controller/IRSA/CRD, VPC CNI NetworkPolicy 활성화를 확인한다.
2. 실제 환경 값·SSM·이미지·앱 계약·영속 볼륨을 준비하고 main에 반영한다.
3. workload, backend-networking, observability targets의 diff와 적용 순서를 함께 검토한다.
4. backend-networking 수동 Sync 후 `kubectl -n app get targetgroupbinding backend`와 Target Health를 확인한다.
5. HTTPS /healthz, Backend 업무 요청, Prometheus target UP을 확인한다. 외부9090은 실패해야 한다.
6. controller 관리 시험 Pod로 SGLang callback8080 성공/Ollama 차단/다른 namespace 위장 차단/AI 업무 DB 차단을 검증한다.
7. 실제 AI 인증·multipart 결과 저장까지 확인한다. TCP 연결 성공만으로 앱 연동 성공을 선언하지 않는다.
8. Blue/Green promote 전후 Service endpoint와 TG 대상 등록/해제·오류율을 확인한다.
9. Stage 통과 후 Prod에서 반복한다.

설정 rollback은 이전 Git 값으로 되돌린 뒤 수동 Sync한다. enabled=false만으로는 prune=false인 기존 TGB/정책이 제거되지 않는다.
TGB 삭제는 대상 등록 해제를 동반하므로 명시적 prune 확인과 서비스 영향 확인 후 수행한다.

근거: [TargetGroupBinding](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/targetgroupbinding/targetgroupbinding/),
[NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/).

## 구현 전 코드 조사 기록 — 2026-09-18 (아래의 미구현 표기는 당시 상태)

### 조사 범위

세 저장소에서 git fetch origin --prune을 실행했다. checkout/pull/merge 없이 원격 추적 ref와 로컬 코드를 대조했다.
Backend·GenAI는 각각 아래 원격 HEAD와 로컬 HEAD가 같았다. infra의 미커밋 작업은 보존했다.

| 저장소 / ref | 커밋 | 의미 |
| --- | --- | --- |
| infra origin/main | 5f16310c1516d9c1dcd61588639f045791f1a94a | 현재 merge된 기준 |
| infra origin/feat/edge-module | 99a3275 | ALB·WAF·ACM 모듈 작성 브랜치 |
| infra origin/feat/eks-addons | 02febf7 | VPC CNI NetworkPolicy 활성화 코드; main 미반영 |
| Backend origin/develop | 9f2f489169af699c5746c1a64dba3307d153e285 | 운영 profile·외부 호출·AI callback 조사 |
| GenAI origin/main | 9528d11d47dd18fd6de4806659347b5097af1be6 | chatbot·page_generation·배포 entrypoint 조사 |

### ALB 권장안: Terraform 소유 + TargetGroupBinding

terraform/modules/alb/main.tf가 ALB, IP Target Group, HTTPS listener, HTTP redirect, WAF association,
Route53 alias까지 정의한다. outputs.tf는 target_group_arn을 네이티브 연결용으로 제공한다.
조회한 origin 원격 브랜치들의 terraform/environments에서 해당 모듈 호출은 찾지 못했다.
따라서 **모듈 작성 완료**, **환경 연결 미확인**, **AWS 실제 배포 미확인**을 구분한다.

기존 Terraform 모듈을 살리는 방향을 권장한다. 이것은 코드에 근거한 제안이지 팀 합의가 이미 완료됐다는 뜻은 아니다.

- 인프라: 환경별 ALB/TG/리스너/ACM/WAF/DNS/SG 생성·관리.
- 네이티브: AWS Load Balancer Controller/IRSA 설치 주체 확인, TargetGroupBinding → backend-active:8080 연결, NetworkPolicy 관리.
- Rollouts: active Service selector 전환. Controller가 대상 Pod IP를 갱신하므로 수동 IP 등록은 하지 않는다.
- Preview는 별도 외부 ALB/TG를 만들지 않고 내부 Service로 검증한다.
- 같은 ALB/TG를 Ingress와 Terraform이 동시에 관리하지 않는다.

다음 코드 변경은 현재 Ingress template을 TargetGroupBinding으로 교체하고 AppProject에 elbv2.k8s.aws 리소스 권한을 추가하는 것이다.
이 조사에서는 배포 manifest를 변경하지 않았다. 인증서/WAF/도메인 설정은 Terraform 소유로 돌리고,
네이티브에는 환경별 targetGroupARN, vpcID, 실제 ALB source subnet CIDR을 제공받는 형태로 단순화한다.
별도 SG 규칙을 TGB networking 필드에 중복 선언하지 않고 인프라 SG 계약과 맞춘다.

[공식 TargetGroupBinding 문서](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/targetgroupbinding/targetgroupbinding/).

### Backend 외부 통신: 실제 운영 코드 기준

| 출발지 → 목적지 | 포트 | 코드 근거 / 결정 |
| --- | --- | --- |
| Backend → api.tosspayments.com | TCP 443 | PaymentProperties/TossPaymentsGateway. TOSS_API_BASE_URL override 가능 |
| Backend → info.sweettracker.co.kr | TCP 443 | SweetTrackerProperties/DeliveryTrackingGateway. 환경 override 가능 |
| Backend → kauth.kakao.com | TCP 443 | OAuth token 교환. 로그인 authorization 화면은 브라우저 요청과 구분 |
| Backend → kapi.kakao.com | TCP 443 | OAuth user-info |
| Backend → nid.naver.com | TCP 443 | OAuth token 교환 |
| Backend → openapi.naver.com | TCP 443 | OAuth user-info |
| Backend → MAIL_HOST | TCP 587 기본 | 운영 profile MAIL_PORT override, STARTTLS 사용. Gmail/465는 추정해서 허용하지 않음 |
| Backend → 환경 S3 | TCP 443 | S3ImageStorage의 HeadObject/DeleteObject/PutObject 실제 호출 |
| Backend → regional STS | TCP 443 | IRSA 채택 시 SDK 자격 증명 획득 경로. 실제 사용 endpoint 확인 |

OAuth는 **현재 prod 코드가 Kakao + Naver**다. 이전 Google 설명을 최신 기준으로 사용하지 않는다.
Presigned URL 생성과 브라우저의 직접 S3 업로드는 Backend S3 업로드와 다르지만,
현재 Backend에는 확인·삭제·AI 결과 업로드 API가 있으므로 Backend S3 egress는 필요하다.
IMAGE_BASE_URL/프론트 redirect/CORS origin은 응답 URL 또는 브라우저 경로다. 문자열이 있다고 Backend egress로 추가하지 않는다.

내부 통신은 Backend→CNPG 5432, 두 AI API 8000, Collector 4317, CoreDNS TCP/UDP 53이다.
Backend 운영 profile에는 REDIS_HOST/6379가 있고 Redis token store도 있다. Redis는 사용자 결정대로 배포 보류이며
통신 대상도 미정이다. 이 부분은 NetworkPolicy 완료로 덮지 않고 Backend 운영 의존성 확인 항목으로 남긴다.

### AI 통신: chatbot과 상세페이지 구분

| 출발지 → 목적지 | 포트 | 상태 |
| --- | --- | --- |
| Ollama API Pod → 전용 벡터DB | TCP 5432 | 기존 정책 존재 |
| chatbot API → 같은 Pod Ollama | TCP 11434 | localhost 기본값. Pod 간 포트를 열 필요 없음 |
| 상세페이지 API → 같은 Pod SGLang text/image | TCP 30000/30001 | deploy/sglang Dockerfile의 loopback 설정. 외부 Service 불필요 |
| 상세페이지 API → Backend callback | TCP 8080 제안 | 실제 persist HTTP POST 존재. backend-active 내부 DNS를 사용해야 함 |
| 두 AI API → Collector | TCP 4317 | 대기 egress 번들에 작성됨 |
| 모델 초기화 → 모델 배포처 | 보통 TCP 443 | 실제 이미지/캐시 준비 방식에 따라 필요. 목적지 전체 목록 미확정 |
| AI → S3/STS | TCP 443 조건부 | 설계상 모델 S3 가능. 조사한 Python 런타임에서 직접 S3 SDK 호출은 확인하지 못함 |

상세페이지 backend_client.py의 BackendProductClient.persist는 multipart HTTP POST를 수행하며,
Backend의 /internal/generations/complete/multipart가 수신한다. BACKEND_URL이 없으면 delivery pending/error 경로로 간다.
권장 URL은 http://backend-active.app.svc.cluster.local:8080/internal/generations/complete/multipart 이다.
BACKEND_AUTH_TOKEN, Backend 내부 인증, DTO 일치 검증도 필요하며 여기에는 실제 값을 저장하지 않는다.

따라서 기존 ‘AI→Backend 전부 차단’은 수정해야 한다. **ai-sglang만 Backend 8080 허용, ai-ollama는 계속 차단**을 제안한다.
Backend ingress와 AI egress 양쪽에 대응 규칙을 둔다. NetworkPolicy는 /internal 경로만 허용할 수 없으므로 인증은 앱에서 수행한다.

chatbot의 SentenceTransformer(BAAI/bge-m3), 상세페이지의 Hugging Face 모델·rembg 캐시는
캐시가 비어 있으면 다운로드가 필요할 수 있다. 현재 코드를 ‘S3만 접근하면 됨’으로 해석하면 안 된다.
정확한 CDN/redirect 목적지를 추측해 허용하지 않는다. 모델을 사전 준비해 serving 중 외부 다운로드를 줄이는 방향을 권장한다.
Playwright 브라우저/OS 설치는 상세페이지 Dockerfile의 빌드 단계다. 빌드 네트워크를 Pod egress와 혼동하지 않는다.

추가 불일치: page_generation API는 /health, /health/ready를 제공하지만 infra ai-sglang probe는 /ai/health다.
이 이미지로 배포할 경우 probe·BACKEND_URL/토큰·모델/PVC 계약을 함께 수정해야 한다. 이번 조사는 해당 manifest를 수정하지 않았다.

### DB·플랫폼 외부 통신

| 주체 | 필요한 경로 | 현재 상태 |
| --- | --- | --- |
| CNPG Instance Manager | Kubernetes API HTTPS, DNS, 복제 5432 | API endpoint 예외 미완성 |
| CNPG 백업 주체 | S3·STS HTTPS | 현재 Cluster에 backup 설정 없음. 백업 구현 후 호출 주체에만 허용 |
| Loki / Tempo | S3·STS HTTPS | Loki 전체 egress 미격리, Tempo는 승인 CIDR runtime 입력 대기 |
| Alertmanager | Discord HTTPS | 선택 구성, 목적지 제한 방식 미확정 |
| Grafana CloudWatch | AWS API HTTPS | 데이터소스 미구현, 현재 필수 통신으로 추가하지 않음 |
| Argo CD repo-server | GitHub·선택 Helm repo HTTPS | 실제 dependency repo/redirect 포함 확인 필요 |
| Argo CD/Rollouts/Operator/Alloy Events | Kubernetes API HTTPS | 실제 EKS API 경로 기반 정책 필요 |
| ALB Controller | Kubernetes API·ELB/EC2/STS 등 AWS HTTPS | 설치 주체·IRSA·목적지 계약 필요 |
| CSI AWS provider | SSM·STS·필요 시 Secrets Manager HTTPS | 파일을 쓰는 앱과 AWS 호출 주체를 구분; hostNetwork/노드 경로 확인 |

Image pull은 kubelet/containerd의 노드 통신이며 앱 Pod ECR egress 예외가 아니다.

### NetworkPolicy 최종 정리와 구현 순서

1. Terraform ALB 연결 방식 인계 후 Ingress 초안을 TGB로 교체. ALB source→Backend:8080 정책 유지.
2. 상세페이지 callback의 ai-sglang→Backend:8080 예외 추가. Ollama→Backend/AI→업무 DB 차단 유지.
3. SGLang의 실제 image/probe/backend URL/토큰 공급 계약 정렬.
4. Backend 외부 API, AI 모델 준비, DB API/백업의 실제 목적지와 통제 방식을 확정하고 egress 번들 활성화.
5. Monitoring/Argo의 기존 넓은 제어 포트 허용과 미격리 egress를 별도 축소.
6. 실제 EKS에서 새 연결로 허용·차단, callback 저장, Blue/Green target 전환, 메트릭/로그/trace를 검증.

표준 NetworkPolicy에는 도메인을 직접 넣을 수 없다. DNS 조회 IP를 영구 고정하거나 0.0.0.0/0:443을 최소권한 완료로 표현하지 않는다.
동적 외부 API는 승인 CIDR 운영 또는 별도 proxy/firewall 등 통제 방식을 인프라·보안과 결정해야 한다.

origin/feat/eks-addons의 vpc_cni_config에는 enableNetworkPolicy를 설정하는 코드가 있다. main merge/실제 apply 성공과는 다르다.
EKS에서 aws-node network policy agent와 PolicyEndpoint가 동작하는지 확인한다. 테스트 송신기는 Deployment 등 controller가 관리하는 Pod를 사용한다.
[AWS NetworkPolicy 고려사항](https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy.html).

이번 작업은 최신 코드 조사와 문서 정리다. Terraform·Backend·GenAI 및 배포 정책의 동작은 변경하지 않았다.

## Redis·백업 통신 반영 — 2026-09-18

업무 Redis의 과거 보류 표기는 해제했다. 두 환경에 App 노드 Redis와 ingress/egress 정책을 연결했다. `app` namespace의 Backend label Pod만 Redis TCP 6379에 접근하며 Redis 자체 신규 egress는 없다. Backend 전체 egress 번들의 Redis 허용도 작성되어 있다(그 번들의 활성화는 기존 외부 통신 계약 이후).

CNPG 백업 chart 활성화 시 `cnpg-system` Operator → Barman plugin TCP 9090을 허용한다. DB sidecar → S3/regional STS TCP 443의 실제 목적지는 환경 인계 대상이며 DB 전체 egress 차단 번들은 해당 입력 없이 활성화하지 않는다. [Redis 계약](../../k8s/base/redis/README.md), [백업 절차](../cnpg-backup/README.md)를 참조한다.
