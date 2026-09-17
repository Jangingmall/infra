# [K8s] 클러스터 안 배포 - 순수 애플리케이션 매니페스트

## 공통 설정과 환경별 설정

`base`는 Namespace, StorageClass, Backend, DB, AI의 공통 설정을 관리한다. `overlays/stage`와 `overlays/prod`는 이 공통 설정을 참조하는 환경별 진입점이다.

| 경로 | 용도 |
| --- | --- |
| `base` | 모든 환경이 공유하는 Kubernetes 리소스 |
| `overlays/stage` | Staging 클러스터의 배포 설정 |
| `overlays/prod` | Production 클러스터의 배포 설정 |

폴더 이름 `stage`는 [GitOps 설계](https://app.notion.com/p/bd40842d874f8338b21d01984da9bcf4)의 표기를 따른다. AWS 환경 이름 `staging`을 변경하는 설정이 아니다.

Stage와 Prod는 별도 EKS 클러스터를 사용하는 설계다. 따라서 Namespace, Service, ServiceAccount 등 리소스 이름은 공통 base의 이름을 유지한다. 두 overlay를 같은 클러스터에 적용하면 같은 리소스를 갱신하므로 환경이 분리되지 않는다. 실제 배포 연결 시 각 환경의 Argo CD Application이 올바른 클러스터를 가리키도록 구성해야 한다.

## 현재 구현 범위

두 overlay 모두 공통 base를 참조한다. Stage·Prod 모두 업무 DB 수신 정책 2개와 AI API 수신 정책 2개, AI 벡터DB 전용 수신·발신 정책 1개를 포함한다. 이미지·리소스 등 환경별 차이가 확정되면 해당 overlay에 `patches` 또는 `images` 설정을 추가한다.

- 이미지: Backend·AI의 실제 ECR 이미지가 전달되면 환경별 `images`로 지정한다. Production은 Staging에서 검증한 동일 이미지 SHA/Digest를 사용한다.
- Replica·CPU·메모리: 현재 base 값을 상속한다. 환경별 운영 수치가 확정되면 patch로 관리한다.
- 도메인·IRSA·시크릿: 실제 연결 값과 사용 방식이 확정된 뒤 환경별 설정을 추가한다.

Backend·AI 이미지에는 아직 base의 자리표시자(`jangin-app`, `jangin-ai/sglang`, `jangin-ai/ollama`)가 사용된다. 이번 구조 추가는 배포 준비 단계이며, 실제 이미지·인증·설정 연결 및 EKS 실행 검증까지 완료된 상태는 아니다.

## AI 전용 벡터DB

T4 GPU 노드에 PostgreSQL/pgvector StatefulSet과 EBS PVC를 추가했다. Ollama만 TCP 5432로 접근하며 DB는 GPU를 요청하지 않는다. 자원은 실측 전 초기값이고 Redis는 보류한다. Secret 공급, 초기화, 테스트와 운영 제한은 [벡터DB 문서](base/ai/vector-db/README.md)를 따른다.

## Stage·Prod DB 수신 NetworkPolicy

[팀 NetworkPolicy 설계](https://app.notion.com/p/0190842d874f824b992c01ff46f92006)의 DB부터 단계적으로 적용하는 순서에 맞춰, 첫 단계는 `database` Namespace의 수신 통신(Ingress)을 제한한다.

정책은 `base/network-policies/database`에 관리하지만 최상위 `base/kustomization.yaml`에는 등록하지 않는다. Stage·Prod overlay가 같은 정책 경로를 직접 참조한다. 이는 두 환경의 배포 선언이며 실제 배포 완료를 의미하지 않는다. 운영 반영 전 Stage에서 통신을 검증한다.

- `default-deny-ingress`: `database` Namespace의 모든 Pod를 수신 격리 대상으로 선택한다.
- `allow-cnpg-ingress`: `cnpg.io/cluster: jangingmall-postgres` 라벨을 가진 Pod에 아래 통신을 허용한다.

| 출발 | TCP 포트 | 목적 |
| --- | --- | --- |
| `app`의 `app.kubernetes.io/name: backend` Pod | `5432` | 애플리케이션 DB 접근 |
| `database`의 `cnpg.io/cluster: jangingmall-postgres` Pod | `5432` | 같은 CNPG 클러스터의 복제·초기화·재합류 |
| `cnpg-system`의 CNPG Operator Pod | `8000` | 인스턴스 상태 조회·관리 |

각 허용 규칙은 Namespace 조건과 Pod 라벨 조건을 같은 `from` 항목에 두어 둘 다 만족하는 출발지만 선택한다. CNPG Operator는 현재 검증 스크립트의 Helm release `cloudnative-pg`, chart `0.29.0`을 렌더링해 확인한 `app.kubernetes.io/name: cloudnative-pg`와 `app.kubernetes.io/instance: cloudnative-pg` 라벨을 사용한다. release 이름이나 Pod 라벨을 바꾸면 정책도 함께 확인해야 한다.

AI와 그 밖의 허용되지 않은 Pod에는 DB 접근을 허용하지 않는다. 모니터링 수집기 설정이 아직 없으므로 DB 지표 포트 `9187`의 허용 규칙도 현재는 없으며, 수집기의 실제 Namespace·Pod 라벨을 확정한 뒤 추가한다. CNPG 포트 용도는 [공식 보안 문서](https://cloudnative-pg.io/docs/1.30/security/#exposed-ports)를 기준으로 한다.

두 환경에 연결한 DB 정책의 `policyTypes`는 `Ingress`만 지정한다. 따라서 현재 두 overlay는 DB 발신 통신(Egress)을 제한하지 않는다. 발신 정책의 공통 부분은 아래 별도 묶음으로 준비하며, 환경별 필수 예외와 함께 연결하기 전에는 일반 인터넷 발신 차단이 완료된 상태가 아니다.

### DB Egress 공통 정책 — 환경 연결 대기

`base/network-policies/database/egress`에는 다음 정책을 작성했다. 이 경로는 상위 database kustomization과 Stage·Prod overlay 모두에서 참조하지 않는다.

| 정책 | 대상 | 동작 |
| --- | --- | --- |
| `default-deny-egress` | `database`의 모든 Pod | 발신 기본 차단 |
| `allow-cnpg-internal-egress` | `cnpg.io/cluster: jangingmall-postgres` Pod | CoreDNS TCP·UDP 53, 같은 CNPG 클러스터 TCP 5432 허용 |

DNS 목적지는 `kube-system` Namespace와 `k8s-app: kube-dns` Pod 라벨을 동시에 선택한다. 실제 CoreDNS 라벨과 Pod의 DNS 경로를 확인해야 하며, NodeLocal DNS를 사용하면 해당 경로에 맞춘 별도 검토가 필요하다. CNPG 초기화·재합류 Job도 실제 `cnpg.io/cluster` 라벨을 확인한다.

**이 묶음만 클러스터에 적용하면 CNPG의 Kubernetes API 접근과 STS·S3 접근이 차단된다.** 아래 환경별 예외가 준비되기 전에는 `apply -k`하거나 overlay에 추가하지 않는다. 로컬 검증 스크립트는 이 묶음을 렌더링만 한다.

| 환경별 필수 예외 | 포트 | 구현에 사용할 정보 |
| --- | --- | --- |
| CNPG → Kubernetes API | TCP 443 | 실제 API Endpoint 목적지와 Service 주소 변환 후 CNI 적용 대상 |
| 백업 워크로드 → STS | TCP 443 | IRSA 사용 주체, regional endpoint 및 안정적인 목적지 제한 방식 |
| 백업 워크로드 → S3 | TCP 443 | 리전 S3 목적지 CIDR 목록·갱신 방법, Gateway Endpoint 경로 |

문서에 정해진 NAT Gateway·S3 Gateway Endpoint 사용 방침은 유지한다. S3 Prefix List ID를 NetworkPolicy의 `ipBlock`에 직접 넣을 수는 없다. CIDR 규칙을 사용하면 목록의 변경 추적·갱신 방법도 함께 정해야 하며, 버킷·오브젝트 접근 범위는 IAM·Endpoint Policy·Bucket Policy에서 제한한다. STS의 일회성 DNS 조회 결과를 영구 허용 IP로 간주하지 않는다.

#### 환경별 예외에 필요한 정보

2026-09-16에 확인한 [DB 값·CI 설정](https://app.notion.com/p/4b20842d874f828d9177010594b880c9)과 [팀 컨텍스트 v0.8](https://app.notion.com/p/17f0842d874f83328a0d81a3cde78dfe)에는 S3 Gateway Endpoint 및 라우팅 연결이 완료됐다고 기록되어 있다. 문서의 Endpoint는 `vpce-02f0b4007562d1132`, S3 Prefix List는 `pl-78a54011`이다. 이 기록을 Stage의 실제 리소스나 현재 AWS 상태로 간주하지 않고 대상 계정·VPC를 확인한다.

[EKS 생성 전 결정 문서](https://app.notion.com/p/0eb0842d874f82afa9fe811f9e99b3e5)는 NAT·EKS 생성 전 상태와 API 공개 범위 논의가 남아 있음을 명시한다. 따라서 전체 VPC CIDR을 API 주소 대신 허용하거나, NAT EIP를 STS 목적지 IP로 넣지 않는다. NAT EIP는 이 통신에서 외부에 보이는 출발지 주소다.

| 항목 | 이미 확인한 내용 | 추가로 필요한 결과 |
| --- | --- | --- |
| DB Service | `jangingmall-postgres-rw.database.svc.cluster.local:5432` | 실제 Service endpoint 및 Pod 라벨 |
| S3 | Gateway Endpoint 사용, 문서에 Prefix List ID 있음 | 대상 환경의 현재 CIDR 목록·목록 버전, 갱신 담당·방법 |
| STS | NAT 경유 IRSA 토큰 교환 계획 | 실제 regional endpoint·호출 Pod, 목적지 제한 및 주소 변경 대응 방식 |
| Kubernetes API | EKS 생성 후 주소 확정 | Service/EndpointSlice와 실제 API endpoint·접근 방식 |
| 백업·복원 | `cnpg-backup-sa` 사용 계획 | 실제 백업 구성의 호출 Pod 및 복원 테스트 Cluster 라벨 |

현재 규칙은 `jangingmall-postgres`만 선택한다. 문서에 제안된 `jangingmall-postgres-restore-test`는 별도 클러스터이므로 현재 허용 대상이 아니다. 복원 리허설 리소스와 함께 필요한 수신·발신 허용을 별도로 작성하며, 이를 위해 database 전체 Pod에 백업 접근을 허용하지 않는다.

인프라팀 또는 권한을 인계받은 담당자는 아래 **읽기 전용** 명령으로 값을 확인할 수 있다. AWS 프로필·클러스터 이름은 실제 인계값으로 바꾼다. 생성·변경·배포 명령은 포함하지 않는다.

```bash
NP_AWS_PROFILE='<실제 AWS 프로필>'
NP_CLUSTER='<실제 Stage 클러스터 이름>'
aws eks describe-cluster \
  --profile "$NP_AWS_PROFILE" --region ap-northeast-2 --name "$NP_CLUSTER" \
  --query 'cluster.{endpoint:endpoint,network:kubernetesNetworkConfig,vpc:resourcesVpcConfig}'
aws ec2 describe-managed-prefix-lists \
  --profile "$NP_AWS_PROFILE" --region ap-northeast-2 \
  --filters Name=prefix-list-name,Values=com.amazonaws.ap-northeast-2.s3 \
  --query 'PrefixLists[].{id:PrefixListId,version:Version,name:PrefixListName}'
aws ec2 get-managed-prefix-list-entries \
  --profile "$NP_AWS_PROFILE" --region ap-northeast-2 \
  --prefix-list-id '<위에서 확인한 Prefix List ID>'
```

위 조회 결과만으로 STS의 안정적인 최소 허용 범위까지 자동 결정되는 것은 아니다. 해당 제한 방식이 정해지고 필수 경로가 검증될 때까지 Egress 묶음의 환경 연결은 대기한다.

연결 순서는 다음과 같다.

1. 환경별 API·STS·S3 허용 규칙을 작성하고 실제 호출 Pod를 선택한다.
2. 공통 Egress 묶음과 환경별 예외를 같은 Stage 변경에 포함한다. 필수 목적지 값이 빠진 예시는 배포 경로에 넣지 않는다.
3. DNS·CNPG 복제·API·자격 증명·백업/복원을 검증하고, 허용되지 않은 외부 목적지로의 새 연결 차단을 확인한다.
4. Stage 검증 후 Prod 목적지 값으로 별도 연결한다.

### 실제 적용 전 확인

이번 변경의 범위는 **두 환경의 DB·AI 수신 정책, 두 AI Deployment·Service와 아직 활성화하지 않은 DB·AI Egress 및 Backend 공통 정책**이다. NetworkPolicy 전체 구현 완료와 구분한다.

| 단계 | 현재 상태 | 완료 조건 |
| --- | --- | --- |
| DB·AI Ingress | 각 2개 정책을 Stage·Prod overlay에 연결 | 로컬 렌더링 및 Stage 허용·차단 통신 검증 |
| DB Egress | DNS·CNPG 내부 통신 및 기본 차단 작성, 환경 연결 대기 | Kubernetes API·STS·S3 예외 구현 후 공통 정책과 함께 연결·검증 |
| DB Metrics `9187` | 미허용 | Prometheus의 실제 Namespace·Pod 라벨 확정 후 최소 허용 |
| App·AI 정책 | AI 수신은 양쪽 환경 연결, Backend 전체·AI 발신은 대기 | ALB·외부 서비스·AWS·관측성 예외와 실제 AI 이미지 확인 후 나머지 연결·검증 |
| Monitoring·Argo 정책 | 미구현 | 수집·컨트롤러·외부 서비스 통신 경로 확정 후 구현 |
| Prod 정책 연결 | DB·AI 수신 규칙 포함, Backend·Egress는 대기 | 실제 배포 전 Stage 검증 결과와 환경 차이 확인 |

DB Egress를 구현하려면 인프라팀에서 EKS API 접근 방식과 목적지 범위, DNS 구성, STS 접근 방식, S3 목적지 범위·Gateway Endpoint 경로를 받아야 한다. 백업 구성에서 어떤 Pod가 실제로 STS·S3를 호출하는지도 확인한다. 표준 NetworkPolicy는 AWS 서비스 이름이나 FQDN을 목적지로 지정할 수 없으므로, 미확정 값을 임의의 CIDR 또는 전체 HTTPS 허용으로 대체하지 않는다.

## AI 두 Runtime 배포 선언

[9/16 최종 협업 요청사항](https://app.notion.com/p/3dd0842d874f8125ac29fe52292d7504)의 Kubernetes Runtime 구조에 맞춰 다음 Deployment·Service를 공통 base에 선언했다. 따라서 Stage·Prod 모두 같은 두 리소스를 포함한다.

| Deployment / Service | 노드 조건 | 이미지 교체 키 | Backend 호출 주소 |
| --- | --- | --- | --- |
| `ai-sglang` | `workload-type=gpu`, `gpu-model=l40s` | `jangin-ai/sglang` | `http://ai-sglang.ai.svc.cluster.local:8000` |
| `ai-ollama` | `workload-type=gpu`, `gpu-model=t4` | `jangin-ai/ollama` | `http://ai-ollama.ai.svc.cluster.local:8000` |

각 Deployment는 replica 1, GPU limit 1, Recreate, `nvidia.com/gpu=true:NoSchedule` toleration을 사용한다. Service는 각 Runtime의 고유 name 라벨만 선택하므로 두 엔진 사이에 요청이 섞이지 않는다. IRSA ServiceAccount는 문서의 `ai-worker-sa`를 공유한다. Ollama 11434 및 SGLang 내부 엔진 포트는 Service로 공개하지 않는다.

문서는 각 이미지가 FastAPI 8000과 해당 엔진을 제공하도록 AI팀에 요청하고 있으며, 단일 컨테이너와 동일 Pod의 다중 컨테이너 여부는 회신 대기다. 현재는 기존 단일 컨테이너 선언 방식을 사용하고 이미지 ENTRYPOINT에 기동을 맡긴다. 실제 이미지·Digest, 모델 로딩·볼륨·환경변수, CPU/Memory는 인계 후 반영한다. 이미지 키는 실제 발행 이미지가 아니다.

Probe는 기존 계약의 `/ai/health`를 유지한다. 새 요청 문서의 `/health`는 예시이므로 확정으로 간주하지 않는다. 각 이미지에서 8000 바인딩과 실제 health 경로, 모델 로딩 후 readiness 및 startup 시간 예산을 확인해야 한다. 실제 클러스터 기동은 아직 검증하지 않았다.

기존 `Deployment/ai-worker`, `Service/ai-worker`는 이 선언에서 `ai-sglang`으로 이름이 바뀌었다. 이미 배포된 환경이라면 Backend의 두 endpoint 설정 전환과 기존 리소스 정리를 함께 계획해야 한다. 특히 기존 GPU Pod가 남으면 새 SGLang Pod가 GPU 부족으로 Pending될 수 있다. GitOps prune 여부를 확인하고, Stage에서 이전 Pod 종료·신규 Pod 배치·각 Service endpoint를 검증한다. 기존 Service가 두 엔진을 무작위 분산하도록 호환 alias를 만들지 않는다.

## Backend·AI 공통 정책 — 환경 연결 대기

부속 B의 내부 통신 계약을 다음 두 독립 Kustomize 묶음으로 작성했다. Backend 전체 묶음과 AI 전체 묶음은 배포 경로에 연결하지 않는다. AI API의 `ingress` 하위 묶음은 DB 수신 정책과 함께 Stage·Prod에서 참조한다. 전용 벡터DB 정책은 AI base를 통해 별도로 포함된다.

| 묶음 | 작성한 규칙 |
| --- | --- |
| `base/network-policies/backend` | app Namespace 수신·발신 기본 차단, Backend Pod → CoreDNS TCP·UDP 53 / 해당 CNPG 클러스터 TCP 5432 / ai-sglang·ai-ollama TCP 8000 허용 |
| `base/network-policies/ai` | ai Namespace 수신·발신 기본 차단, Backend Pod → 두 AI Runtime TCP 8000 수신 허용, 두 AI Runtime → CoreDNS TCP·UDP 53 및 Ollama → 전용 벡터DB TCP 5432 발신 허용 |

허용 규칙의 Namespace와 Pod 라벨은 같은 peer에 두어 두 조건을 모두 만족해야 한다. Backend는 기존 Rollout의 `app.kubernetes.io/name: backend`를 선택하므로 active·preview Pod 모두 해당한다. AI는 name 라벨이 `ai-sglang` 또는 `ai-ollama`인 Pod만 `matchExpressions/In`으로 선택한다. 다른 앱·추론 엔진 라벨을 임의로 추정해 허용하지 않는다.

Backend → DB는 Backend 발신과 기존 DB 수신 규칙이, Backend → AI는 Backend 발신과 AI 수신 규칙이 서로 대응한다. 전체 묶음에는 AI → 업무 CNPG DB 및 AI → Backend의 새 연결 예외가 없다. Ollama → AI 전용 벡터DB는 별도 TCP 5432 예외를 사용한다. 현재 overlay에서는 DB 수신 정책으로 AI → DB를 제한하지만, AI 발신 및 Backend 수신 차단이 미연결이므로 AI → Backend 차단까지 구현된 상태는 아니다. Backend가 시작한 요청에 대한 AI 응답은 별도 Callback 연결이 아니다. 기본 차단은 Namespace 전체를 선택하지만 허용은 지정된 워크로드만 선택하므로, 나중에 추가한 다른 Pod가 자동으로 허용되지는 않는다.

**두 묶음을 단독 적용하면 Backend의 ALB 수신과 외부 호출, AI 모델 다운로드 등이 차단된다. 아직 `apply -k`하거나 overlay에 연결하지 않는다.** 다음 예외를 작성하고 정상 통신을 확인한 뒤 순차 연결한다.

| 대상 | 연결 전 남은 구현 |
| --- | --- |
| Backend | 실제 ALB 출발지 → 8080, 수집 Pod → 9090, 사용 중인 PG·OAuth·택배·SMTP, 실제 Pod의 AWS 호출, 선택한 OTLP 경로 |
| AI | 실제 모델 다운로드·STS·S3 경로, 수집 Pod → 8000, 선택한 OTLP 경로 |
| DB | Kubernetes API·STS·S3 발신 예외, 실제 수집 Pod → 9187, 복원 클러스터용 규칙 |

ALB를 Kubernetes Pod selector로 표현하지 않는다. 실제 출발지·경로에 맞춰 환경별 수신 예외를 구성한다. Monitoring 라벨이 아직 구현되지 않았으므로 Namespace 전체에 메트릭 접근을 열지 않는다. 외부 HTTPS 전체 허용 및 미확정 SMTP·OTLP 포트 동시 허용으로 예외를 대신하지 않는다. AI 8000은 HTTP 경로를 구분하지 않는 포트 단위 허용이며 `/metrics`만 제한하는 정책이 아니다.

### Backend·AI Stage 테스트 계획

DB 단계 검증 후 Backend, AI 순으로 진행한다. 각 단계의 필수 예외를 먼저 완성하고, 적용 전 정상 연결을 기준으로 적용 후 **새 연결**을 비교한다. 처음부터 실패하는 목적지는 정책 차단의 증거로 사용하지 않는다. 테스트 리소스는 Stage에서만 사용하고 실행 후 정리한다.

| 테스트 | 기대 결과 |
| --- | --- |
| Backend active·preview Pod → DB Service:5432 | 실제 조회 성공 |
| Backend → ai-sglang·ai-ollama 각각의 Service:8000 | 각 API 응답 성공, 응답 반환 정상, Service가 올바른 엔진만 선택 |
| Backend·AI → 실제 CoreDNS | UDP·TCP DNS 조회 성공 |
| app Namespace에서 Backend 라벨 없는 테스트 Pod → DB·AI | 새 연결 차단 |
| 다른 Namespace에서 Backend와 같은 라벨을 가진 테스트 Pod → DB·AI | 새 연결 차단 |
| AI → 업무 CNPG DB:5432 및 Backend:8080 | 새 연결 차단 |
| Backend → DB:8000 또는 비허용 목적지 | 새 연결 차단 |
| ALB → Backend:8080 | 예외 추가 후 health check·요청 정상 |
| Backend의 외부 API·메일, AI 모델 다운로드 | 각 예외 추가 후 기능 정상 |
| 메트릭·트레이스 수집 | 수집기·OTLP 예외 추가 후 정상 |

DB는 위 DB 검증표의 복제·재합류·Operator 관리와 Egress 연결 후 백업·복원도 확인한다. 여러 노드의 실제 워크로드를 대상으로 수행하며 기존 정책의 추가 허용과 CNI 예외를 확인한다. IP 직접 연결과 Service 연결을 구분해 DNS 오류를 차단으로 오판하지 않는다.

[Q-CN-08 답변](https://app.notion.com/p/3dd0842d874f8091a9cfe5b8efafaa21)에 맞춰 **명령어 실행 로그 + 결과표 + 주요 스크린샷**을 남긴다. 각 결과에는 코드 버전·Stage context·출발 Pod 라벨·목적지·포트·적용 전후 결과를 적는다. 장애가 나면 이번 단계에서 추가한 정책 변경을 GitOps로 되돌리고 정상 기능 회복을 확인한다. 실제 실행 결과가 확보되기 전에는 이 표를 검증 완료로 표시하지 않는다.

- EKS VPC CNI의 NetworkPolicy 지원·활성화 상태를 확인한다. YAML 렌더링만으로 통신 차단 여부를 확인할 수 없다.
- 실제 CNPG 인스턴스·초기화 Job Pod와 Operator Pod의 라벨을 확인한다.
- 같은 DB Pod를 선택하는 기존 NetworkPolicy를 확인한다. 허용 규칙은 합쳐지므로 다른 정책이 접근을 허용하면 이 기본 차단 정책만으로 해당 접근을 막을 수 없다.
- 기존 리소스의 정상 연결을 먼저 확인하고 정책 적용 후 새 연결로 아래 결과를 비교한다. 연결 실패가 DNS·Service·애플리케이션 오류 때문인지도 구분한다.

| 검증 대상 | 기대 결과 |
| --- | --- |
| Backend → DB `5432` | 연결 성공 |
| 같은 클러스터의 DB 복제·새 인스턴스 합류 | 정상 동작 |
| CNPG Operator → DB `8000` | 연결 성공 및 상태 관리 정상 |
| AI 또는 허용되지 않은 Pod → 업무 CNPG DB `5432` | 새 연결 차단 |
| `app`의 Backend 외 Pod → DB `5432` | 새 연결 차단 |
| Backend → DB `8000`, 모니터링 → DB `9187` | 현재 규칙에서는 새 연결 차단 |
| DB DNS·Kubernetes API·기존 STS/S3 접근 | 정책 적용 전후 동작 유지 |

연결 검증용 Pod는 실제 VPC CNI의 적용 조건에 맞게 Deployment 또는 Job으로 생성하고, 여러 노드에서 검증한다. NetworkPolicy에는 노드 트래픽 등 구현상 예외가 있으며, 검증 범위는 [Kubernetes 정책 동작](https://kubernetes.io/docs/concepts/services-networking/network-policies/)과 [EKS 적용 조건](https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy.html)을 함께 확인한다.

### Stage 검증 기록

실제 Stage context와 접근 권한을 받은 뒤 아래 읽기 전용 명령으로 대상을 확인한다. `STAGE_CONTEXT`에는 인계받은 context 이름을 넣는다.

```bash
kubectl config get-contexts
STAGE_CONTEXT='<실제 Stage context>'
kubectl --context "$STAGE_CONTEXT" get namespaces --show-labels
kubectl --context "$STAGE_CONTEXT" -n database get pods --show-labels -o wide
kubectl --context "$STAGE_CONTEXT" -n cnpg-system get pods --show-labels -o wide
kubectl --context "$STAGE_CONTEXT" -n app get pods --show-labels -o wide
kubectl --context "$STAGE_CONTEXT" -n kube-system get pods -l k8s-app=kube-dns --show-labels -o wide
kubectl --context "$STAGE_CONTEXT" -n default get service kubernetes -o wide
kubectl --context "$STAGE_CONTEXT" -n default get endpointslices -l kubernetes.io/service-name=kubernetes -o wide
kubectl --context "$STAGE_CONTEXT" -n database get networkpolicies -o yaml
kubectl --context "$STAGE_CONTEXT" -n database get cluster jangingmall-postgres
```

VPC CNI의 정책 활성화 여부는 인프라팀의 add-on 설정과 실제 네트워크 정책 에이전트 상태로 확인한다. 위 명령에서 Pod가 조회되는 것만으로 정책이 활성화됐다고 판단하지 않는다.

정책 적용 전후 통신 Matrix를 같은 조건에서 비교하고, 다음을 PR 또는 검증 기록에 남긴다.

- 검증한 코드 버전, Stage 클러스터, 적용한 정책 및 기존 정책 목록
- 출발 Pod의 Namespace·라벨·노드와 목적 Pod/Service·포트
- 적용 전 연결 성공 여부, 적용 후 새 연결의 성공·차단 결과
- Backend DB 접근, CNPG 복제·재합류·Operator 상태 관리 결과
- DNS·Service endpoint·리스닝 상태 확인 결과: 단순 연결 실패만을 차단 증거로 사용하지 않는다.
- 검증하지 못한 항목과 원인; 결과가 없으면 EKS 검증 완료로 표시하지 않는다.

## 로컬 렌더링과 검증

저장소 루트에서 실행한다. 아래 명령은 최종 YAML을 출력하며 클러스터에 적용하지 않는다.

```bash
kubectl kustomize k8s/overlays/stage
kubectl kustomize k8s/overlays/prod
kubectl kustomize k8s/base/network-policies/database/egress
kubectl kustomize k8s/base/network-policies/backend
kubectl kustomize k8s/base/network-policies/ai
```

공통 base, 두 overlay, 연결 대기 중인 DB Egress·Backend·AI 정책과 기존 세 플랫폼 Helm 차트를 함께 검증하려면 다음을 실행한다.

```bash
bash scripts/validate-k8s.sh
```

GitHub Actions도 같은 스크립트를 실행한다. 도구 버전, 실행 조건과 검증의 한계는 [저장소 검증 안내](../README.md#kubernetes-설정-검증)를 참고한다.

## Backend 자원·HPA·DB 연결 수

Stage·Prod 공통으로 Backend requests 700m/1Gi, limits 2 CPU/4Gi, HPA min 2/max 4,
HikariCP 최대 10·최소 idle 5·연결 대기 3000ms, CNPG max_connections 200을 선언한다.
CPU 목표 70%는 실측 전 초기값이다. Blue/Green 최대 운영 승격 시 단일 전환 기준 8개 Pod를 계획하며,
현재 App 노드 한 대로는 수용할 수 없다. [자원 예산과 배포 전 조건](base/backend/README.md)을 확인한다.

## Backend configtree

Stage·Prod overlay는 환경별 SecretProviderClass와 공통 configtree component를 포함한다.
SSM 값을 `/mnt/secrets-store/`의 파일로 마운트해 Spring 설정으로 읽는다.
Naver 계약을 기준으로 작성했으며 실제 IRSA ARN, SSM 값 준비, Backend의 Google·이메일 URL 불일치 해결은 남아 있다.
[매핑·동작 과정·배포 전 조건](components/backend-configtree/README.md)을 확인한다.
