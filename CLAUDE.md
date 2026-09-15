# 장인몰 인프라 — 클라우드 인프라 파트 (`CLAUDE.md`)

> kt cloud TECH UP 2기 3팀 "삼성가고싶어요" 통합프로젝트 · 서비스 **장인몰**
> Claude Code가 매 세션 자동으로 읽습니다. **결정사항 위주로 짧게 유지하세요.**
> 기준: **통합프로젝트 Context 2026-09-14** + **팀 컨텍스트 v0.8** + **네트워크·계정 설계서 최종본(9/14)** + **모듈화 전략 B안(9/15 19:21 파트장 최종)** + **비용 보고서 v1.0**
> 최종 갱신 **2026-09-15** (이전판 09-14)
>
> 🔴 **현재 AWS 상태: 리소스 없음.** 9/15 파트장님이 기존 네트워크 리소스를 destroy 하셨습니다.
> 코드는 `main` 에 남아 있으나 **모듈 구조로 재작성 후 재생성**해야 합니다.

---

## 나에 대해

- **신준한** / 클라우드 인프라 과정 **서브 파트장**
- **담당: 네트워크·보안 (PR 매니저)** — VPC/서브넷/라우팅, NAT, SG, SSM
- **타 직군 소통 담당: 사이버보안팀**
- **나는 현업자가 아니라 학생이다.** 도구·개념·코드가 처음인 경우가 많으니 압축해서 넘어가지 말 것.
- 최종 결정권자가 아님 — 파트장(강윤주)·그룹장 합의가 필요한 사안은 그 점을 명시할 것.

## 응답 방식

1. 쉬운 언어 + 비유로 "이게 뭐고 왜 필요한지"
2. 실제 코드/설정을 한 줄씩 주석 풀듯 해석
3. 전문가 관점 — 실무에선 왜 이렇게 하나 / 트레이드오프 / 초보가 흔히 하는 실수

한국어 존댓말. 솔직한 분석 선호(사탕발림 금지). 표·코드블록·다이어그램 적극 활용.

---

## 🔴 지금 막혀 있는 것 (코드 짜기 전 확인)

| # | 항목 | 담당 | 없으면 |
|---|---|---|---|
| 1 | **ECR 태그 규칙** (BE `sha-` vs 다정님 `staging-`/`prod-`) | CN+다정+BE | CI 이미지 승격 |
| 2 | **메일 SMTP 세부** ("google email"만 회신) | BE | 아웃바운드 포트·시크릿 |
| 3 | **App `requests` 구체값** | BE | 롤링 배포 가능 여부 |
| 4 | **AI 컨테이너 이미지·모델 배포 경로** | AI | NAT 처리료 $13 |
| 5 | **staging / prod 운영 방식** (가)순차·(나)staging축소·(다)prod단일 | 파트장 + 그룹장 | **동시 운영은 예산 2배로 불가** |
| 6 | **공용 ECR State 위치** — 🔴 현재 `ecr_enabled = false` **양쪽 다 꺼져 있음** | 창원 + 파트장 | **BE가 `docker push` 못 함** (다정님 안내 이미 발송됨) |
| 7 | **최종 설계서 ↔ 코드 차이 4건** (아래 「설계서 차이」) | 파트장 | ⑦⑧ 코드 작성 |
| 8 | **EKS 버전 · 인증 모드 · 엔드포인트 공개** | 파트장 + 다정 + 보안 | 🔴 **되돌릴 수 없는 결정** — 별도 안건 문서 |
| **9** | 🆕🔴 **Redis 미설계** — BE 회신에 `redis-host`·`redis-port` **필수**로 등장 | 인프라 + CN + BE | **리소스·비용 산정에 Redis가 없음** |
| **10** | 🆕🔴 **App 노드 메모리** — BE `-XX:MaxRAMPercentage=75` + limit 4Gi → 힙 최대 3Gi.<br>t3.medium(allocatable ≈3.4Gi)에 Pod 2개 = **OOM 위험** | 인프라 + CN + BE | ⑦ 노드그룹 사이징 |
| **11** | 🆕 **ALB Idle Timeout** — BE가 **SSE + AI 응답 Streaming** 사용. 기본 60초면 끊김 | 인프라(⑩) | SSE 연결 유지 |
| **12** | 🆕 **`jangin-staging-build` EC2 정체** — 다정님 SSM 안내에 등장. 기존 설계엔 **Bastion·빌드 EC2 없음** | 다정 + 파트장 | 신규 리소스면 **비용 미산정** |
| **13** | 🆕 **DNS 서브도메인 `stg.` vs `staging.`** | 파트장 | Route53·CORS·FE env |

> 위 값이 안 나온 상태에서 **임의값으로 채우지 말 것.** `variable` + `TODO` 주석으로 남기고 진행.

### ✅ 9/15 해소된 것

| 항목 | 결론 |
|---|---|
| **이미지 버킷 CloudFront OAC vs 공개** | ✅ **CloudFront OAC 사용 확정** (9/15 회의). 모듈은 파트장님 PR #15 (`acm_cloudfront`·`cloudfront`) |
| **변수 파일 규칙 A안 vs B안** | ✅ **B안(환경별 통합) 최종 확정** (9/15 19:21 파트장). 아래 「B안 변수 컨벤션」<br>*경위: 오전 A안 → 인프라가 `-var-file` 누락 리스크 지적 → 파트장 재검토 → **B안 정정 확정***<br>*"tfvars 가 여러 개 쓰는 게 더 번거로울 것 같네요. 굳이 지금 A안으로 가야 하는 이유가 없는 것 같아서 정정해서 B안으로 가는 게 맞는 것 같습니다. (tfvars 는 각 환경 별로 하나씩)"* |

---

## 팀 구성

| 이름 | 담당 | 타 직군 창구 |
|---|---|---|
| 강윤주 (파트장) | 엣지 — ALB·WAF·Route53·ACM, 모니터링 | 팀장 · PM · 전체 조율 |
| **신준한 (나)** | **네트워크/보안 — VPC/서브넷/라우팅, NAT, SG, SSM** | **사이버보안** |
| 박다정 | 계정/비용 — IAM, 비용 분석, 문서화 | **백엔드(계정·시크릿·외부연동)** |
| 이창원 | DB & DR — DB, ECR+CI/CD, RTO, 비용 산정 | 생성형AI · 프론트엔드 |
| 박명수 (네이티브) | k8s 워크로드 — Deployment/Ingress, ArgoCD, RBAC | **백엔드(앱 런타임)** |

- PM: 전영원 / 그룹 부반장: 고영롱(사이버보안)
- **RACI**: 인프라 = 6.아키텍처 설계 **R/A**, 10.프로비저닝·모니터링 **R/A** / **11.CI-CD·GitOps는 네이티브가 A** — 흡수 금지

---

## ✅ 확정 스택

| 영역 | 확정 |
|---|---|
| IaC | **Terraform** (State: 전용 S3 + DynamoDB Lock — **CLI 수동 생성 승인**) |
| 클라우드 | **AWS 단일** |
| 리전 | **`ap-northeast-2` (서울)** |
| 계정 | 공용계정 1개 + IAM Identity Center. **SSO Start URL**: `https://d-9b675a5254.awsapps.com/start` |
| 오케스트레이션 | **EKS** |
| **환경 분리** | **staging / prod 별도 클러스터 · 별도 VPC** (Peering 없음) |
| **NAT** | ✅ **NAT Gateway** (AZ-a 단일 + **EIP 고정**) — ~~NAT Instance~~ 폐기 |
| LB | **ALB (target-type `ip`)** + **AWS WAF** · Pod Readiness Gate 병행 |
| **DNS** | apex `midam.store` → Vercel / `api.midam.store` → ALB<br>🟡 **스테이징 서브도메인 `stg.` vs `staging.` — 파트장 확인 필요**<br>(리소스 **이름 접두사**는 9/14 설계서 최종본에서 `staging` 으로 통일됐으나, **DNS 서브도메인은 별개 축**이라 자동 변경하지 않음) |
| **DB** | **CloudNativePG** — Primary 1 + Replica 2 |
| 레지스트리 | ECR — **단일 레포 `jangin-app` + 동일 아티팩트 승격** · **Immutable** |
| **시크릿** | Parameter Store **`/{env}/{team}/{key}` (3단)** + KMS CMK<br>**CSI Driver → 볼륨 마운트 → Spring `configtree`** (Secret Sync 미사용) |
| **AI 런타임** | **EKS GPU 직접** — g6e.xlarge(이미지·SGLang) + g4dn.xlarge(챗봇·Ollama) |
| S3 | **5종** — images / returns / backup / models / logs |
| CI/CD | GitHub Actions → ECR → ArgoCD → EKS |
| 레포 | **`infra` 단일** + `terraform/`·`k8s/`·`argocd/` |
| 모니터링 | Prometheus + Grafana + **Loki(S3 백엔드)** — **Kubecost 미도입** |
| **비용 분석** | **Cost Explorer + Athena(CUR)** |

### 트래픽 경로 (내 담당 영역)

```
인바운드  : 사용자 → Route53(DNS 조회) → WAF → ALB → App Pod : 443→8080 (/healthz)
앱↔DB     : App Pod ↔ CNPG Pod : 5432                      (양방향)
앱→AI     : App Pod → GPU Pod : 8000                       (클러스터 내부)
모니터링   : Prometheus → App Pod : 9090                     (클러스터 내부만)
아웃바운드 : 모든 노드 → NAT Gateway(EIP 고정) → IGW : 443
             ├─ 토스페이먼츠(PG) · 카카오/구글(OAuth) · 스마트택배
             ├─ Google SMTP : 587/465
             └─ ECR · STS · EC2 API
S3        : 노드 → S3 Gateway Endpoint (NAT 미경유 · 무료)
이미지조회 : 브라우저 → CloudFront(OAC) → S3 `products/`   ✅ 9/15 확정 · BPA 유지
             업로드는 presigned PUT 으로 S3 직접 (CloudFront 미경유)
관리      : Admin → SSM Session Manager (Bastion 없음, SSH 22 차단)
🔴 차단   : Data→인터넷 ✕ / ALB→9090 ✕ / GPU→DB ✕ / Staging→Prod ✕
```

---

## 🔧 네트워크 확정값 — Terraform 작성 시 이 값

| 환경 | VPC | CIDR |
|---|---|---|
| **prod** | `jangin-prod-vpc` | **`10.0.0.0/16`** |
| **staging** | **`jangin-staging-vpc`** 🔄 (구: `jangin-stg-vpc`) | **`10.1.0.0/16`** |

| tier | 서브넷 | prod | staging |
|---|---|---|---|
| Public | public-a / c | `10.0.0.0/24` · `10.0.1.0/24` | `10.1.0.0/24` · `10.1.1.0/24` |
| Private Data | data-a / c | `10.0.2.0/24` · `10.0.3.0/24` | `10.1.2.0/24` · `10.1.3.0/24` |
| **Private App** | app-a / c | **`10.0.16.0/20` · `10.0.32.0/20`** | **`10.1.16.0/20` · `10.1.32.0/20`** |

- **2 AZ** (ALB가 최소 2AZ 서브넷 요구) · **리소스는 AZ-a에만 배치** (MVP, SPOF 미고려)
- **App만 `/20`**: EKS VPC CNI가 **Pod마다 VPC 실제 IP 할당**. t3.medium 1대가 최대 18 IP. **CIDR은 생성 후 변경 불가**
- **EKS 서브넷 태그 필수** — Public `kubernetes.io/role/elb` · App `kubernetes.io/role/internal-elb`. 빠뜨리면 **ALB Controller가 서브넷을 못 찾아 Ingress 생성 실패**
- **라우팅**: public → IGW / app → **NAT Gateway** + S3 Endpoint / **data는 `0.0.0.0/0` 없음** + S3 Endpoint
- **VPC Endpoint**: **S3 Gateway(무료)만.** ECR Interface는 **미도입 확정** (NAT 처리료 $2.95 vs Endpoint $10.28)

### Security Group 4종 (전부 **SG Reference**, CIDR 금지)

| SG | 방향 | Port | Source/Dest | 비고 |
|---|---|---|---|---|
| `sg-alb` | In | 443, 80 | `0.0.0.0/0` | 80은 443 리다이렉트 |
| | Out | 8080 | `sg-eks-node` | |
| | — | ~~9090~~ | — | 🔴 **절대 금지** — `/actuator/prometheus` 노출 |
| `sg-eks-node` | In | 8080 | `sg-alb` | target-type `ip`라 NodePort 개방 불필요 |
| | In | 9090 | `sg-eks-node` | Prometheus 스크랩 (클러스터 내부만) |
| | Out | 5432 | `sg-db` | |
| | Out | **8000** | `sg-eks-gpu` | AI 추론 |
| | Out | All | `0.0.0.0/0` | NAT GW 경유 |
| | Out | 443 | S3 Prefix List | Gateway Endpoint |
| `sg-db` | In | 5432 | `sg-eks-node` | **이것만** |
| | Out | All | `0.0.0.0/0` | 이미지 pull·STS (NAT GW) |
| | Out | 443 | S3 Prefix List | WAL 백업 |
| **`sg-eks-gpu`** | In | **8000** | `sg-eks-node` | 추론 요청 |
| | Out | All | `0.0.0.0/0` | 이미지 pull·STS |
| | Out | 443 | S3 Prefix List | 모델 가중치 |
| | ~~Out~~ | ~~5432~~ | ~~`sg-db`~~ | 🔴 **만들지 않음** |
| ~~`sg-nat`~~ | — | — | — | **소멸** — NAT Gateway는 SG 부착 불가 |

### 리소스 네이밍 규칙

```
일반:  jangin-<env>-<resource>          # env = prod | staging  (🔄 09-14: stg → staging 통일)
       jangin-prod-vpc / jangin-staging-subnet-public-a / jangin-prod-sg-db

ECR:   jangin-app  (환경 구분 없이 단일 레포, 태그로 구분)
```
- **환경 세그먼트가 앞쪽**에 있어야 IAM 정책에서 `jangin-prod-*` 로 자를 수 있음
- 리소스명은 **`locals`로 조립**
- ⚠️ S3 버킷명은 **전역 고유** — 충돌 시 접미사

### 공통 태그 (비용 분석 선행조건)

```hcl
locals {
  prefix = "${var.project}-${var.environment}"   # jangin-prod
  tags = {
    Project     = "jangin"
    Environment = var.environment      # staging | prod
    ManagedBy   = "Terraform"
    NodePool    = "system|app|db|ai"   # Cost Explorer 필터링용
    Owner       = "infra"
  }
}
```

🔴 **태그가 없으면 Cost Explorer 역할별 필터링이 안 됩니다** (다정님 비용 분석 전제).

---

## 노드 구성 ✅ 확정

| 노드그룹 | 인스턴스 | 대수 | 과금시간 | 워크로드 |
|---|---|---|---|---|
| **System** | `t3.medium` | **2** | 264h | Prometheus·Grafana·Loki·ArgoCD·ALB Controller |
| **App** | `t3.medium` | **1** | 102h | Backend Pod |
| **DB** | `t3.small` | 3 | 102h | CNPG Primary 1 + Replica 2 |
| **GPU-A** | **`g6e.xlarge`** (L40S 48GB) | 1 | 102h | 이미지·텍스트 (SGLang) |
| **GPU-B** | **`g4dn.xlarge`** (T4 16GB) | 1 | 102h | 챗봇 (Ollama) |

### GPU 노드그룹 — 🔴 `desired_size = 0`으로 생성

9/10 AI팀 방침: *"AI팀 요청 들어올 때까지 GPU 안 띄워도 될 것 같다"*
→ **`min_size=0, desired_size=0`** 으로 만들어두면 **요청 시 값 하나로 즉시 기동**, 그전까지 **$0**. 9/18 가동완료는 "구성 완료·기동 대기"로 충족.

```
Label:  workload-type=gpu, node-lifecycle=spot
        gpu-model=l40s  (GPU-A)  /  gpu-model=t4  (GPU-B)
Taint:  nvidia.com/gpu=true:NoSchedule   (양쪽 동일)
```

🔴 **`gpu-model` 라벨이 없으면** 챗봇 Pod가 비싼 g6e에 뜨거나 이미지 Pod가 T4에서 OOM.

### GPU 스토리지 — **로컬 NVMe** (루트 EBS 상향 불필요)

g6e 250GB / g4dn 125GB NVMe를 **containerd 데이터 루트 + kubelet ephemeral**로 사용 (Launch Template userData).
⚠️ **Instance Store라 노드 종료·Spot 회수 시 소멸.** 컨테이너 이미지·모델 캐시·임시 데이터만.

---

## IRSA 6종 ✅ 확정

| # | ServiceAccount | IAM Role | 권한 |
|---|---|---|---|
| 1 | `kube-system:ebs-csi-controller-sa` | `jangin-{env}-irsa-ebs-csi` | EBS 볼륨 (없으면 **CNPG Pod `Pending`**) |
| 2 | `kube-system:aws-load-balancer-controller` | `jangin-{env}-irsa-alb-controller` | ALB 생성 (없으면 **Ingress 만들어도 ALB 안 생김**) |
| 3 | **`app:backend-sa`** | `jangin-{env}-irsa-backend` | Parameter Store + `kms:Decrypt` + **`kms:GenerateDataKey`** |
| 4 | **`database:cnpg-backup-sa`** | `jangin-{env}-irsa-cnpg` | S3 백업 + **`kms:GenerateDataKey`** |
| 5 | **`monitoring:loki-sa`** | `jangin-{env}-irsa-loki` | `s3-logs` 접근 |
| 6 | **`ai:ai-worker-sa`** | `jangin-{env}-irsa-ai` | `s3-models` 최소권한 |
| — | ~~`secrets-store-csi-driver`~~ | **만들지 않음** | Workload SA가 직접 보유 |

> ⚠️ **OIDC Provider 등록이 선행조건.** 빠뜨리면 `sts:AssumeRoleWithWebIdentity` 오류가 나는데 원인이 잘 안 드러남
> 🔴 **`kms:GenerateDataKey` 누락 시** SSE-KMS 버킷 업로드가 실패하는데, **에러가 KMS인지 S3인지 구분이 안 됨**

---

## S3 버킷 5종 + State

| 버킷 | 용도 | 공개 | 암호화 |
|---|---|---|---|
| `jangin-{env}-s3-images` | 상품 이미지 | 🟡 **CloudFront vs 공개 — 결정 대기** | SSE-S3 |
| `jangin-{env}-s3-returns` | 반품 증빙 | **비공개** | **SSE-KMS(CMK)** |
| `jangin-{env}-s3-backup` | CNPG WAL·백업 | 비공개 | **SSE-KMS(CMK)** |
| `jangin-{env}-s3-models` | AI 가중치 | 비공개 | SSE-S3 |
| `jangin-{env}-s3-logs` | **4가지 용도 — 아래** | 비공개 | SSE-KMS |
| `jangin-infra-s3-tfstate` | Terraform State | 비공개 | SSE-KMS + 버전관리 + TLS 강제 |

**`s3-logs` prefix 분리 필수**

```
s3-logs/cloudtrail/   ← 장기보관 (멘토 요구)
        s3-access/    ← S3 접근 로그 (보안팀)
        vpc-flow/     ← VPC Flow Logs (보안팀 NAT 조건 4)
        loki/         ← Loki 청크 (단기)
```
🔴 prefix를 안 나누면 lifecycle이 엉켜 **비용이 샙니다.**

### CORS ✅ 확정 (FE 회신)

```json
{
  "AllowedMethods":  ["PUT"],
  "AllowedHeaders":  ["Content-Type"],
  "AllowedOrigins":  ["https://midam.store", "http://localhost:3000"],
  "ExposeHeaders":   ["ETag"],
  "MaxAgeSeconds":   3000
}
```
- **GET 불필요** — `<img src>`·`next/image`(서버 fetch)라 CORS 대상 아님
- **staging 버킷에는 `https://stg.midam.store` 추가**
- ⚠️ **SSE-KMS는 버킷 기본 암호화로 강제.** 버킷 정책에 *"암호화 헤더 없으면 Deny"* 를 **넣지 않음** (넣으면 FE가 헤더를 보내야 함). TLS 강제 Deny는 유지

### 공통 버킷 정책 (보안팀 요구)

| 조치 | 구현 |
|---|---|
| TLS 강제 | `aws:SecureTransport = false` Deny |
| ACL 비활성화 | `Object Ownership = Bucket owner enforced` |
| 접근 로깅 | → `s3-logs/s3-access/` |
| 익명 권한 (공개 시) | `products/*` `s3:GetObject`만. **`ListBucket`·`Put`·`Delete`·ACL 금지** |

---

## 타 직군 (인프라가 전제로 삼는 것)

**🖥 BE** — Java 25 · Spring Boot 4.0.3 · PostgreSQL 18 · 모놀리식 · HTTPS만
- **관리 포트 9090 분리** / 서비스 `:8080`
- ✅ **CPU2/RAM4GB = `limits`.** requests는 최소 (App t3.medium 1대 근거)
- ✅ **ALB Health Check**: `8080 /healthz` · healthy 2 / unhealthy 3 / timeout 5s / interval 30s
- ✅ **graceful shutdown 30s** → 인프라 **`deregistration_delay = 30s`** (기본 300초)
- ✅ **Parameter Store 3단** `/{env}/{team}/{key}`
- ✅ **objectKey = UUID + 이름** · presigned `POST /api/images/presigned-url` + `purpose` 파라미터
- ✅ 컨테이너 `eclipse-temurin:25-jre` · **non-root** · `linux/amd64` · stdout/stderr 로그
- 🟠 **메일 = "google email"** — SMTP 종류·발신주소·인증방식 미상

**🆕 BE 회신 추가 (2026-09-15, 명수님 경유) — 인프라 영향**

| 내용 | 인프라 영향 |
|---|---|
| 🔴 **Redis 필수** (`redis-host`·`redis-port`) | **리소스·비용 산정에 Redis 없음.** ElastiCache vs k8s Pod 미정 (막힌 항목 9) |
| 🔴 **`-XX:MaxRAMPercentage=75`** + limit 4Gi → 힙 최대 **3Gi** | App t3.medium(allocatable ≈3.4Gi)에 Pod 2개 = **OOM 위험** (막힌 항목 10) |
| 🔴 **SSE + AI 응답 Streaming** 사용 | **ALB Idle Timeout 기본 60초** → 연결 끊김. ⑩ 에서 상향 필요 (막힌 항목 11) |
| 🆕 **Naver OAuth 추가** (기존 카카오/구글) | 아웃바운드 대상 1종 추가 — NAT 경유 · NetworkPolicy egress |
| ✅ **Secret 22종 목록 확정** | **Parameter Store 경로 설계 가능** (⑧). PG·택배 2종은 미구현 |
| ✅ Actuator 포트 **9090** · `health`·`prometheus` | 기존 `sg-eks-node` in 9090(self) 규칙과 **일치** |
| ✅ **JSON Structured Log** | Loki 파싱에 유리 |
| ✅ `@Scheduled` **중복 실행 고려됨** | Pod 2개 + Blue/Green 환경에서 안전 |
| 🟠 **Request ID(MDC) 미구성** | Loki 에서 요청 단위 추적 불가 — 🔗 CN·BE 협업 |

**🆕 다정님 BE 안내 (2026-09-15) — 인프라 작업 발생**

- BE 는 **SSO `Backend-Dev` 퍼미션셋**으로 접근. **Access Key 미발급 방침** ✅
- 🔴 **노드 IAM 역할에 `AmazonSSMManagedInstanceCore` 필요** — ⑦ 노드그룹 단계 인프라 작업. 현재 코드에 없음
- 🔴 **ECR `enabled = false`** 라 BE 가 아직 `docker push` 불가 — 막힌 항목 6
- 🟡 **`jangin-staging-build` EC2** 언급 — 기존 설계엔 Bastion·빌드 EC2 **없음**. 정체 확인 필요 (막힌 항목 12)

**🎨 FE** — Next.js + **Vercel Pro(SSR)** · **브라우저에서 WebP 3종 변환** → presigned로 S3 직접 PUT
- ✅ CORS 확정값 (위) · ✅ **EXIF 자동 제거** (원본 업로드 경로 없음)
- ✅ **staging FE 배포** — `stg.midam.store`

**🤖 AI** — **EKS GPU 직접** (Modal 폐기)
- ✅ **포트 8000** · `/ai/chat` · `/ai/products` · `/ai/health`
- 이미지 **SGLang** (vLLM 미지원) / 챗봇 **Ollama** — gemma2 9B Q4_0 + BGE-M3
- 🔴 **챗봇 모델 미확정** · CUDA 재포팅 9/11 or 9/15 불확실
- ⚠️ **Ollama 기본 포트는 11434** — 8000은 앞단 uvicorn 추정. Pod 내부 구조 확인 필요

**🔐 보안** — 3-tier · SG Reference · IRSA · **CSI Driver 볼륨 마운트**
- **NAT Gateway 조건부 승인 5건** — 아래
- **AI Pod DAST 범위 편입** · **스테이징 GPU 필요** (스캔 시점만)
- 🔴 **CloudFront OAC 권고** · **EXIF 서버측 백스톱 권고** (MVP는 잔여위험)
- IAM: Root MFA · AccessKey 미생성 · **한시적 admin 9/15~17 회수**
- 스테이징 DAST 8항목

### NAT Gateway 조건 5건 (보안팀)

| # | 조건 | 대응 |
|---|---|---|
| 1 | **Pod 아웃바운드 통제 유지** — NetworkPolicy + Node SG + NACL 병행 | 🔗 CN |
| 2 | **Data 계층 인터넷 직접 접근 금지** | ✅ `rt-data`에 `0.0.0.0/0` 없음 |
| 3 | **모니터링 지표** — `ErrorPortAllocation` · `PacketsDropCount` 필수 | 인프라 |
| 4 | **CloudTrail 유지 + VPC Flow Logs** | 인프라 |
| 5 | **AZ 단위 NAT GW임을 명시** — AZ-a 장애 시 아웃바운드 전체 중단 | 문서화 |

---

## 🔴 작업 규칙

| # | 규칙 |
|---|---|
| 1 | **`apply`/`destroy`는 사람이 plan 확인 후.** `-auto-approve` 금지 |
| 2 | **자격증명·시크릿·계정 ID를 코드·문서에 넣지 않음** — `data.aws_caller_identity` |
| 3 | `*.tfstate`·`*.tfvars`·`.env`·`*.pem` **커밋 금지** |
| 4 | 리전은 `variable`, **AZ 이름 하드코딩 금지** (`data.aws_availability_zones`) |
| 5 | **SG는 CIDR이 아닌 Security Group Reference** |
| 6 | **`sg-alb` inbound에 9090 금지** |
| 7 | **`rt-data`에 `0.0.0.0/0` 만들지 않음** |
| 8 | **`sg-eks-gpu → sg-db` 규칙을 만들지 않음** |
| 9 | **NAT EIP는 `prevent_destroy`** — 택배사 allowlist용. 재생성 시 배송조회 중단 |
| 10 | 리소스명은 **`locals`로 조립** · **`NodePool` 태그는 과금 리소스에만** (아래 참고) |
| 11 | **하나의 Commit/PR = 하나의 작업 단위** (CONVENTION.md) |
| 12 | **과도한 오버엔지니어링 금지** |
| 13 | **CN 과업(컨테이너화·CI·관찰성·NetworkPolicy)을 인프라 산출물로 흡수하지 않음** |
| **14** | **prod 를 고치면 staging 반영 여부를 PR 본문에 명시** — 🔄 09-14 모듈화 전환 후에는 *"공유 모듈 수정인지 / 환경 tfvars 수정인지"* 를 명시 |
| **15** | 🔴 **이미 배포된 리소스를 모듈로 옮길 때만** `moved` 블록을 같은 PR 에 필수 포함. `terraform state mv` CLI 사용 금지(코드에 흔적이 안 남아 다른 팀원 `plan` 에서 destroy 재발)<br>🔄 09-15: 네트워크는 **destroy 후 재생성**이라 이번엔 해당 없음 |
| **16** | 🔴 **`plan` 에 예상치 못한 `destroy` 가 있으면 즉시 중단.** 이관 PR 은 `0 to add, 0 to change, 0 to destroy` 출력을 PR 본문에 첨부 |
| **17** | 💰 **비용이 발생하는 리소스(⑤NAT·⑥EKS·⑦노드그룹 등)는 9/17 까지 `plan` 까지만.** `apply` 는 **9/18 일괄** (파트장 지시). **과금이 없는 작업(VPC·SG·Endpoint 재생성)은 이 규칙 대상 아님** |
| **18** | 🆕🔴 **남이 만든 파일을 확인 없이 `cp`·`mv` 로 덮지 않는다.** 대상 경로에 파일이 있는지 `ls` 로 먼저 확인 (09-12 `.gitignore` 25줄 파괴 · 09-15 `modules/network/main.tf` 덮어쓰기) |
| **19** | 🆕 **커밋 전 `git status` 첫 줄(브랜치명) 확인** (09-13 잘못된 브랜치 커밋) |
| **20** | 🆕 **리소스 이름·버킷명·경로를 제안하기 전에 이 문서의 확정값을 먼저 확인** (09-12 State 버킷명 임의 제안 사고) |

> 📌 **규칙 10 보충 (2026-09-13)**: `NodePool` 값은 `system｜app｜db｜ai` 중 하나여야 Cost Explorer 필터가 의미를 갖습니다.
> VPC·서브넷·IGW·라우팅·SG·Endpoint 는 **요금이 $0** 이고 저 넷 중 어디에도 속하지 않으므로 **부여하지 않습니다.**
> 억지로 `network` 같은 값을 넣으면 비용 분석 필터만 오염됩니다. **⑦ 노드그룹 단계에서 리소스별로 부여합니다.**
> (파트장·다정님 확인 요청 중)

---

## 💰 비용 (확정본 v1.0 · 17일 · 환율 1,342)

| 구분 | 금액 |
|---|---|
| **GPU 2대** (Spot 9일 + OD 2일) | **$183.84 (53.1%)** |
| EKS 컨트롤플레인 (408h) | $40.80 |
| EC2 노드 3종 | $40.72 |
| NAT Gateway (408h + 50GB) | $27.02 |
| Vercel Pro | $20.00 |
| 그 외 | $33.55 |
| **총액** | **$345.93 = 464,241원** |
| Spot 절감 | $115.53 (25.0%) |

- 🔴 **크레딧 $0** — IAM Identity Center **조직 인스턴스** 활성화로 소멸
- 🔴 **프리티어 없음** — EC2 DB라 RDS 무료 대상 아님. t3 전 계열 무료 시간 없음
- 🔴 **예산 $350의 98.8%**
- 💡 **최대 절감 레버: g6e → g6 $88.78** (AI VRAM 실측 선행)

### 🔴 끌 수 있는 것과 없는 것

| 구분 | 항목 | 시간 |
|---|---|---|
| **상시 408h** | **EKS 컨트롤플레인(끌 수 없음)** · NAT GW · ALB 기본료 · 공인 IPv4 3개 | 17일×24h |
| 운영일 264h | System 노드 × 2 | 11일×24h |
| 운영시간 102h | App · DB · GPU · ALB LCU | 11일×9.25h |

⚠️ **ALB를 못 끄는 이유**: Ingress를 지웠다 만들면 **ALB DNS가 바뀌어** Route53을 매일 갱신해야 함

---

## 📅 일정

| 시점 | 내용 |
|---|---|
| ✅ **9/12 (토)** | **IaC 착수** — Claude Code 세팅 · **① State 부트스트랩** (PR #3) |
| ✅ **9/13 (일)** | **② VPC (PR #4) · ③ SG (PR #5) · ④ S3 Endpoint (PR #6)** — 관리 리소스 41개 · $0 |
| ✅ **9/14 (월)** | 보안팀 검토 요청 · 타 직군 질문 · **파트장 설계서 최종본 수령** · 로컬 동기화 |
| ✅ **9/15 (화)** | 🔄 **모듈화 B안 최종 확정**(오전 A안 → 저녁 정정) · **CloudFront OAC 확정** · 🔴 **네트워크 리소스 destroy** · PR #12·#15·#16 머지 |
| **9/16 (수)** | **B안 구조로 네트워크 재PR → 재apply (과금 $0)** · ⑤⑥⑦⑧ 코드 → **`plan` 까지만** |
| 🔴 **9/17 (목)** | **신준한 정규시간 부재** (개인 작업은 가능) · 🔴 **과금 리소스 apply 금지일** |
| **9/18 (금)** | 🔴 **⑤~⑧ 일괄 `apply`** · **프로비저닝 완료** |
| 9/15~17 | IAM 한시적 admin 회수 (박다정) |
| **9/21** | **실제 연동 테스트 시작** · 스테이징 제공(DAST) |
| 9/22 (화) | 인프라 멘토링 3차 |
| **~9/30** | **평일 6일간 검토** (파트장 9/15 확정) |
| 9/24~27 | **추석 연휴 + 주말** — 운영 중단 |
| **10/1~10/4** | 🔄 **노드 내리기** (비용 절감) |
| **10/2 17:00** | 결과물 제출 |
| **10/5~10/6** | 🔄 **노드 올리고 확인 + 발표 시연 준비** |
| **10/6** | 최종 발표 (30분 + Q&A 20분) |

**운영 스케줄**: 09:00~18:00 (하루 9시간) · 🔄 **실제 서버 가동 약 9일** (파트장 9/15 확정)

> 💰 **비용 재산정 대상**: 기존 v1.0 산정은 **운영일 11일 + 달력 17일** 기준이었습니다.
> 새 일정은 **9/18 시작 · 가동 9일**이라 상시 요금(EKS 컨트롤플레인·NAT·ALB·공인 IPv4) 구간도 **약 13일**로 줄어듭니다.
> → **9/18 apply 직후 재산정**하면 예산 98.8% 압박이 완화될 수 있습니다.

### IaC 착수 순서

```
✅ ① Terraform State (S3 + DynamoDB Lock)   ← CLI 수동 생성      PR #3
✅ ② VPC · 서브넷 6개 · 라우팅 · IGW          ← 무료             PR #4
✅ ③ Security Group 4종 (sg-eks-gpu 포함)     ← 무료             PR #5
✅ ④ S3 Gateway Endpoint                      ← 무료             PR #6
🔄 ②③④ 모듈 구조로 재PR + 재apply             ← 무료 · 9/16     (리소스 destroy됨)
   ⑤ NAT Gateway + EIP(prevent_destroy)       ← 💰 9/18
   ⑥ EKS 클러스터 + OIDC Provider              ← 💰 9/18
   ⑦ 노드그룹 (System/App/DB/GPU×2 — GPU는 desired=0)  ← 💰 9/18
   ⑧ KMS CMK + Parameter Store + IRSA 6종 + 🔴 EBS CSI Driver 애드온
   ⑨ S3 버킷 5종 (prefix·lifecycle·CORS)
   ⑩ ALB · WAF · Route53 · ACM
```

> 🔴 **①~④ 는 9/13 에 배포했으나 9/15 destroy 되었습니다.** ① State 백엔드(S3·DynamoDB)는 그대로 살아 있고, ②③④ AWS 리소스만 삭제됐습니다.
> 🔄 **②③④ 재생성은 과금 $0** 이므로 규칙 17 대상이 아닙니다. **9/16 중 재apply 해야 9/18 에 ⑤ 이후를 얹을 수 있습니다.** (재apply 시점은 파트장 확인 필요)
> 💰 **⑤ 이후는 과금.** 9/17 까지 `plan` 까지만, **9/18 일괄 `apply`** (규칙 17)
>
> 🔴 **⑧ EBS CSI Driver 가 9/18 범위에서 빠지면 안 됩니다.**
> 박명수님이 `k8s/base/storage/gp3-cnpg-storageclass.yaml` 로 **gp3 StorageClass** 를 이미 올려두셨는데,
> StorageClass 는 *"디스크를 이렇게 만들어 달라"* 는 **주문서**일 뿐이고 실제로 EBS 를 만드는 **직원(EBS CSI Driver)** 과
> 그 직원의 **AWS 권한(IRSA `jangin-{env}-irsa-ebs-csi`)** 이 없으면 **PVC 가 `Pending` 에서 영원히 멈춰 CNPG Pod 가 안 뜹니다.**
> ⚠️ EKS 1.23 부터 in-tree EBS 프로비저너가 제거되어 **StorageClass 만으로는 동작하지 않습니다.**
> ⚠️ 노드 IAM Role 에 EBS 권한을 통째로 붙이는 우회법은 **그 노드의 모든 Pod 가 EBS 를 조작**할 수 있게 되므로 금지 — 보안팀 검수 지적 대상.

### Phase3 산출물

| # | 산출물 | 상태 |
|---|---|---|
| 1 | IaC 모듈 코드 + 환경 배포 + **IaC CI plan·정책 검증** | 🔄 CI 검증은 백로그에 없음 |
| 2 | **클러스터 환경 인계 문서** (CN 협업) | ⬜ |
| 3 | 구성 관리 자동화 스크립트 + 이미지 빌드 자동화 | ⬜ |
| 4 | 백업·복원 검증 + **멀티 AZ HA 적용 결과** | 🔴 단일 AZ와 충돌 |
| 5 | **AutoScaling 정책 구성·시연** | 🔴 App 1대라 재검토 |

---

## 리포 컨벤션 (`Jangingmall/infra`)

| 항목 | 규칙 |
|---|---|
| 브랜치 | `카테고리/작업내용` → `feat/vpc-network` |
| 커밋 | `[카테고리]: 설명` → `[Feat]: add VPC and subnets for prod` |
| PR 제목 | `[카테고리] 설명` |
| 원칙 | 초기 세팅만 main 직접, 나머지는 **Branch → PR → Merge** |
| 원칙 | **하나의 Commit/PR = 하나의 작업 단위** |
| 원칙 | **민감정보 커밋 전 반드시 확인** |

### 디렉토리 구조 (🔄 2026-09-15 B안 반영)

```
infra/
├── CLAUDE.md · .claude/settings.json
├── .gitignore · CONVENTION.md · README.md
├── scripts/bootstrap-tfstate.sh        ← State 백엔드 부트스트랩 (CLI)
├── k8s/                                🔗 CN(박명수) — base/{namespaces,backend,database,storage}
├── platform/                           🔗 CN(박명수) — cloudnative-pg / argo-rollouts Helm values
└── terraform/
    ├── modules/                        ← 리소스 정의는 여기에만
    │   ├── network/          VPC·Subnet·IGW·RouteTable·NAT      [인프라 ②⑤]
    │   ├── security/         SG 4종 + Rule 15개                  [인프라 ③]
    │   ├── endpoints/        S3 Gateway Endpoint                 [인프라 ④]
    │   ├── eks/      ⬜ 스캐폴드  Cluster·OIDC·NodeGroup          [인프라 ⑥⑦]
    │   ├── ecr/      ✅ 완료      ECR 레포·수명주기               🔗 [이창원 PR #12]
    │   ├── acm_alb/  ✅ 완료      ALB용 ACM + Route53 검증        🔗 [강윤주 PR #15]
    │   ├── acm_cloudfront/ ✅     CloudFront용 ACM (us-east-1)    🔗 [강윤주 PR #15]
    │   ├── alb/      ✅ 완료      ALB                             🔗 [강윤주 PR #15]
    │   ├── cloudfront/ ✅ 완료    CloudFront + OAC                🔗 [강윤주 PR #15]
    │   └── waf/      ✅ 완료      WAF                             🔗 [강윤주 PR #15]
    └── environments/
        ├── prod/                       ← 🔴 module 호출만. 리소스 직접 선언 금지
        │   ├── versions.tf · backend.tf · providers.tf · locals.tf
        │   ├── vpc.tf                  ← module "network" 호출     ┐
        │   ├── security.tf             ← module "security" 호출    │ 호출 파일은
        │   ├── endpoints.tf            ← module "endpoints" 호출   │ 리소스별로 분리
        │   ├── ecr.tf                  ← module "ecr" 호출         ┘
        │   ├── variables.tf            ← 🔑 이 환경이 쓰는 변수 **전부** (통합)
        │   ├── outputs.tf              ← 🔑 이 환경의 출력 **전부** (통합)
        │   ├── terraform.tfvars        ← 🔑 이 환경의 실제 값 **하나** · 🔴 커밋 금지
        │   ├── terraform.tfvars.example ← 커밋되는 값 예시
        │   └── .terraform.lock.hcl     ← ✅ 커밋 (3플랫폼 해시)
        └── staging/                    ← 같은 모듈 호출 · terraform.tfvars 값만 상이
```

🔴 **경로는 `environments/` 입니다** (`envs/` 아님). 레포 실물 기준.
🔗 **`k8s/` · `platform/` 은 클라우드 네이티브 과정 영역입니다.** 인프라가 임의로 수정하지 않습니다.
🔗 **엣지(acm·alb·cloudfront·waf)는 파트장님 영역**입니다. ⑩ 작업 범위는 파트장님과 조율 후 진행.

### 🆕 B안 변수 컨벤션 ✅ **최종 확정 (2026-09-15 19:21 파트장)**

**파일 규칙** — 호출은 리소스별, 변수·출력·값은 **환경별로 하나씩**

| 파일 | 개수 | 역할 |
|---|---|---|
| `<module>.tf` | 리소스마다 | **모듈 호출만** (`vpc.tf`·`security.tf`·`endpoints.tf`·`ecr.tf` …) |
| `variables.tf` | **환경당 1개** | 이 환경이 쓰는 변수 **전부** 선언 |
| `outputs.tf` | **환경당 1개** | 이 환경의 출력 **전부** |
| `terraform.tfvars` | **환경당 1개** | 이 환경의 실제 값 **전부** · 🔴 `.gitignore` 로 커밋 금지 |
| `terraform.tfvars.example` | 환경당 1개 | 커밋되는 값 예시 |

**🔑 왜 `terraform.tfvars` 인가 — 자동 로드**

Terraform 이 **자동으로 읽는 변수 파일**은 `terraform.tfvars` 와 `*.auto.tfvars`(및 `.json`) 뿐입니다.

```bash
terraform plan        # ← 이것만으로 terraform.tfvars 가 읽힌다
```

이름이 `vpc.tfvars`·`ecr.tfvars` 처럼 나뉘어 있으면 자동 로드가 안 되어 매번 이렇게 쳐야 합니다.

```bash
terraform plan -var-file=vpc.tfvars -var-file=ecr.tfvars -var-file=eks.tfvars ...
```

🔴 **하나 빠뜨리면 에러가 아니라 `default` 값으로 조용히 넘어갑니다.** 창원님 CI/CD 파이프라인에서 특히 위험합니다.
→ 이 지적이 9/15 저녁 **A안 → B안 정정**의 근거가 되었습니다.

**변수명 규칙 — 리소스 전용 변수에는 접두사를 유지**

```hcl
# environments/prod/variables.tf  (환경당 1개, 전부 여기에)
variable "project" { ... }          # 공통 — 접두사 없음
variable "env"     { ... }          # 공통
variable "region"  { ... }          # 공통

variable "vpc_cidr"         { ... } # network 전용
variable "vpc_az_suffixes"  { ... }
variable "vpc_subnet_cidrs" { ... }
variable "eks_cluster_name" { ... } # eks 전용
variable "ecr_repositories" { ... } # ecr 전용 (창원님 기존 명명과 일치)
```

> 💡 **파일은 하나로 합치되 이름은 나눕니다.** 모듈이 늘어날수록 `cluster_name` 같은 일반적인 이름은 충돌하거나 "누구 것인지" 모르게 됩니다.
> 파트장님 B안 예시(`ecr_repository_names`)도 같은 방식입니다.
> **모듈 내부 변수는 접두사 없이** — `module "network" { vpc_cidr = var.vpc_cidr }` 처럼 루트에서 매핑합니다.

⚠️ **`.gitignore` 는 이미 `terraform.tfvars` · `*.tfvars` · `*.tfvars.json` 을 전부 차단하고 `!*.tfvars.example` 만 허용**합니다. 수정 불필요.

⚠️ **`.terraform.lock.hcl`은 커밋합니다.** provider 버전을 팀원 전원이 동일하게 쓰게 하는 파일이라, 빼면 사람마다 다른 provider로 plan이 갈립니다.
커밋 전 반드시 멀티 플랫폼 해시를 넣습니다 — `terraform providers lock -platform=darwin_arm64 -platform=darwin_amd64 -platform=linux_amd64`. 안 하면 인텔 맥·GitHub Actions(linux_amd64)에서 깨집니다.

### 환경 분리 전략 ✅ **확정 (2026-09-14 파트장)**

| 항목 | 방식 |
|---|---|
| 코드 분리 | 🔴 **폴더 분리** — git branch 아님. **각 폴더에서 개별 `apply`** |
| State 분리 | **같은 버킷 · `key` 경로만 분리** — `prod/terraform.tfstate` / `staging/terraform.tfstate` |
| 작성 순서 | **prod 완성 → 모듈로 추출 → staging 은 값(tfvars)만 변경** |
| **모듈화** | ✅ **함** — 리소스 정의는 `modules/` 에만 |
| **변수 파일** | ✅ **B안(환경별 통합) 최종 확정 (09-15 19:21 파트장)** — 위 「B안 변수 컨벤션」 |
| 목적 | 9/21~23 보안팀 DAST 검수 기간에 staging 제공 |
| **운영 방식** | 🔴 **미확정** — staging+prod **동시 운영은 예산 2배로 불가**. (가)순차 / (나)staging축소 / (다)prod단일 중 **그룹장 합의 필요**. 인프라 권고는 **(가) 순차** |

**staging 에서 바꿀 값 — 이것만 다릅니다**

| 파일 | 항목 | prod | staging |
|---|---|---|---|
| `backend.tf` | `key` | `prod/terraform.tfstate` | `staging/terraform.tfstate` |
| `terraform.tfvars` | `env` | `prod` | `staging` |
| `terraform.tfvars` | `vpc_cidr` | `10.0.0.0/16` | `10.1.0.0/16` |
| `terraform.tfvars` | `vpc_subnet_cidrs` | `10.0.*` | `10.1.*` |
| `terraform.tfvars` | `eks_cluster_name` | `jangin-prod-eks-cluster` | **`jangin-staging-eks-cluster`** |

> 💡 **B안이라 바꿀 파일이 `backend.tf` 와 `terraform.tfvars` 딱 둘뿐입니다.** A안이었다면 리소스 수만큼의 tfvars 를 각각 손봐야 했습니다.

> ✅ **09-14 정정: `env_short` 는 만들지 않습니다.**
> 이전 판에는 *"Parameter Store·State key 는 `staging`, 리소스 이름 접두사는 `stg`"* 라며
> `locals.env_short = var.env == "staging" ? "stg" : var.env` 를 두라고 적혀 있었습니다.
> **9/14 네트워크·계정 설계서 최종본에서 리소스 이름 접두사도 `staging` 으로 통일**되어 이 분기가 불필요해졌습니다.
> ```hcl
> # 이제 이거면 충분합니다
> name = "${var.project}-${var.env}"   # jangin-prod / jangin-staging
> ```
> ⚠️ **IAM Deny 접두어도 `jangin-staging-*` 로 맞춰야 합니다** (박다정 확인 필요).
> ⚠️ **DNS 서브도메인(`stg.midam.store`)은 별개 축**이라 이 통일에 자동으로 따라가지 않습니다 — 파트장 확인 필요.

> 🔄 **drift(두 환경이 갈리는 것) — 모듈화로 성격이 바뀝니다**
> **모듈을 공유하므로 리소스 정의 자체의 drift 는 구조적으로 사라집니다.** 대신 두 가지가 남습니다:
> 1. **tfvars 값 drift** — 한쪽만 값을 바꾸는 경우
> 2. **apply 시점 drift** — 모듈을 고쳤는데 한쪽 환경에만 `apply` 한 경우 (🔴 이게 더 위험)
> - prod PR 본문에 **"staging 반영 필요 여부"** 를 체크 항목으로 유지합니다 (규칙 14)
> - 동기화 확인: `diff -r -x '.terraform*' -x '*.tfvars*' terraform/environments/prod terraform/environments/staging`
> - 기대 diff: `backend.tf` 의 `key` 한 줄뿐 (나머지 차이는 전부 tfvars 로)

### 모듈 간 연결 원칙

모듈 B 가 모듈 A 의 리소스를 참조할 때는 **A 의 `output` → B 의 `variable`** 로 전달합니다.

```hcl
# environments/prod/security.tf
module "security" {
  source = "../../modules/security"
  vpc_id = module.network.vpc_id     # ← 이 참조 한 줄이 실행 순서까지 결정한다
}
```

- 🔴 `modules/security` 안에서 `aws_vpc.main.id` 를 직접 쓰면 그 모듈은 네트워크 모듈 없이는 못 쓰는 물건이 됩니다
- 🔴 **`depends_on` 을 쓰지 않습니다.** 위 참조만으로 Terraform 이 "network 먼저"를 압니다(암묵적 의존성). 남발하면 병렬 실행이 막혀 apply 가 느려지고 의존 관계가 코드에서 안 보입니다
- 🔴 **모듈 변수에 `default` 를 두지 않습니다.** 환경에서 값을 빠뜨려도 조용히 넘어가지 않고 실패해야 합니다. 기본값은 `environments/*/` 에만

### `moved` 블록 — 언제 쓰나 (🔄 이번엔 해당 없음)

**이미 배포된 리소스**를 모듈로 옮길 때만 필요합니다. Terraform 은 리소스를 **주소**로 기억해서, `aws_vpc.main` → `module.network.aws_vpc.main` 으로 주소가 바뀌면 *"옛 물건이 사라지고 새 물건이 생겼다"* 로 읽고 **destroy + create** 를 계획하기 때문입니다.

```hcl
moved {
  from = aws_vpc.main                    # 옛 주소
  to   = module.network.aws_vpc.main     # 새 주소
}
```

**검증 기준**: `Plan: 0 to add, 0 to change, 0 to destroy.` + 이동 목록만.

> 🔄 **2026-09-15 현재는 해당 없습니다.** 네트워크 리소스가 destroy 되어 **재생성 방식**이 되었으므로 `moved.tf` 를 만들지 않습니다.
> ✅ **참고 기록**: 9/14 에 `moved` 34블록으로 무중단 이관을 실제로 검증했습니다(닫힌 PR #14). 앞으로 배포된 리소스를 옮길 일이 생기면 그 PR 을 참고합니다.

---

## Claude Code 사용 규칙

`.claude/settings.json`의 `deny`에 `terraform apply`·`destroy`·`state rm`·`import`·`aws iam:*`·`git push` + `Read(*.tfvars|*.tfstate|*.pem)` 가 걸려 있습니다. **지침이 아니라 차단기**입니다.

### 코드 검수 체크리스트 (apply 전 눈으로 확인)

| # | 확인 |
|---|---|
| 1 | **app 서브넷이 `/20`인가** (`/24`로 "정리"해버리는 경우 있음) |
| 2 | **AZ 하드코딩 없는가** |
| 3 | **`rt-data`에 `0.0.0.0/0`이 없는가** |
| 4 | **`sg-alb`에 9090 없는가** |
| 5 | **SG가 SG Reference인가** (`cidr_blocks`면 위반) |
| 6 | **`sg-eks-gpu → sg-db`가 없는가** |
| 7 | **EKS 서브넷 태그 있는가** |
| 8 | **계정 ID·ARN 하드코딩 없는가** |
| 9 | **`NodePool` 태그** — 🔄 **과금 리소스(EC2·EBS·NAT·EKS)에만.** VPC·서브넷·SG 에는 붙이지 않음 (규칙 10) |
| 10 | **NAT EIP에 `prevent_destroy` 있는가** |
| 11 | **이미 배포된 리소스를 모듈로 옮기는가?** — 그렇다면 `moved` 블록 필수 (규칙 15) |
| 12 | **과금 리소스인가?** — 그렇다면 9/18 전에는 `apply` 하지 않음 (규칙 17) |
| **13** | 🆕 **리소스 전용 변수에 `<module>_` 접두사가 붙어 있는가** · **값은 `terraform.tfvars` 하나에 모였는가** (B안 컨벤션) |
| **14** | 🆕 **모듈 `variables.tf` 에 `default` 가 없는가** (환경에서 값 누락 시 실패해야 함) |
| **15** | 🆕 **모듈 안에 `provider` 블록이 없는가** (region·default_tags 는 루트에서 상속) |

💡 **plan 출력**: `Plan: N to add, 0 to change, 0 to destroy`
**`to destroy`가 0이 아니면 절대 apply하지 마세요.**
💡 **모듈 이관 PR 의 기대 출력**: `Plan: 0 to add, 0 to change, 0 to destroy.` + 이동 목록만

---

## 평가 기준 (클라우드·보안 그룹)

**전문성 30**(환경설계·비용통제) / **차별성 30**(운영·보안 리스크 인식) / **완성도 30**(**실제 동작 여부** + 타 직군 인계 문서) / **발표 10**(**비전문가도 이해 가능하게**)

→ 제안할 때 **어느 항목 점수를 노리는지 밝힐 것.**

---

## 🔴 배포 리소스 현황 (2026-09-15 기준)

> 계정 `750240012008` · SSO 프로필 `jangin` · Permission Set `Infra-Admin` · 리전 `ap-northeast-2`

| 구분 | 상태 |
|---|---|
| ① **State 백엔드** | ✅ **살아 있음** — `jangin-infra-s3-tfstate` / `jangin-infra-ddb-tfstate-lock` (TLS 강제 · 버전관리) |
| ②③④ **VPC · SG · Endpoint** | 🔴 **없음** — 9/15 파트장님이 destroy. 9/13 에 만든 관리 리소스 41개 전부 삭제됨 |
| ⑤~⑩ | ⬜ 미생성 |

> 🔴 **이전 판(09-14)에 있던 리소스 ID 표는 전부 무효**라 삭제했습니다.
> `vpc-014f8fb…` 등 예전 ID 를 타 직군 문서·설정에 쓰면 안 됩니다.
> **9/16 재apply 후 새 ID 로 이 표를 다시 채웁니다.** (인계 문서 재료 — 완성도 30점)

**재apply 후 채울 항목**: VPC · subnet ×6 · route table ×3 · IGW · SG ×4 + default SG · S3 Gateway Endpoint · prefix list

---

## 🆕 🔴 설계서 ↔ 코드 차이 — 파트장 확인 요청 4건

> 9/14 「네트워크·계정 설계서 최종본」과 배포된 코드를 대조한 결과. **모듈 이관(9/16) 전에 확정되면 한 번에 반영합니다.**

| # | 설계서 | 현재 코드 | 확인 요청 |
|---|---|---|---|
| **1** | `sg-eks-node` inbound ← `sg-eks-gpu` **8000** | 해당 규칙 없음 (`sg-eks-gpu` in ← `sg-eks-node` 8000 만 존재) | GPU→App **역방향 요청**이 실제로 있는지. 응답 트래픽은 SG 가 stateful 이라 규칙 없이도 통과 |
| **2** | `sg-db` / `sg-eks-gpu` egress 를 **443만** 허용 | egress `all` + S3 prefix list 443 | 🔴 **DNS(UDP/TCP 53)가 막혀 Pod 가 도메인 해석 불가.** 53 추가 or 현행 유지 |
| **3** | `irsa-secrets-csi` 부활 | 미구현 (⑧ 예정) | 🔴 드라이버에 IRSA 를 주면 **모든 Pod 시크릿 조회 가능**. Pod 단위 IRSA 유지 여부 (보안팀 의견 필요) |
| **4** | `NodePool` 태그를 IAM/SSM/S3 까지 | `default_tags` 에서 제외 (규칙 10) | IAM Role·Policy 는 NodePool 개념이 없고 일부는 태그 미지원. 과금 리소스 한정 여부 |

> 나머지 3건(명명 규칙·태그 키 대소문자·output 이름)은 **코드를 설계서에 맞춰 수정**합니다. 별도 확인 불필요.

---

## 변경 이력

**09-15 (모듈화 B안 최종 확정 · 리소스 destroy)**
- ✅ **변수 컨벤션 B안 최종 확정** (파트장 19:21) — 「B안 변수 컨벤션」 신설
  - 경위: 오전 **A안**(리소스별 분리) 지시 → 인프라가 **`-var-file` 누락 시 `default` 로 조용히 넘어가는 리스크** 지적 → 파트장 재검토 → **B안 정정**
  - B안은 `terraform.tfvars` 1개라 **자동 로드**되어 이 문제가 구조적으로 사라짐 → `.auto.tfvars` 제안도 불필요해짐
  - 🔴 **닫은 PR #14 의 코드가 곧 B안 구조** — 커밋 `5135735` 로컬 보존. `moved.tf` 제거 + 호출 파일 분리만 하면 됨
- ✅ **CloudFront OAC 사용 확정** (회의) — 막힌 항목 1번 해소. 모듈은 파트장 PR #15
- 🔴 **네트워크 리소스 destroy** — 리소스 ID 표 전부 삭제, 「배포 리소스 현황」으로 대체
- 🔄 **`moved` 절차를 "이미 배포된 리소스 이동 시에만"으로 한정** — 이번 재생성엔 해당 없음. 규칙 15·16 조건 명확화
- 🔄 **디렉토리 구조 갱신** — 팀 모듈 6종(ecr·acm_alb·acm_cloudfront·alb·cloudfront·waf) 반영, 담당자 표기
- 🔄 **일정 갱신** (파트장 9/15) — 9/18 프로비저닝 → 9/21 연동 → ~9/30 검토 → 10/1~4 노드 내림 → 10/5~6 시연. **가동 약 9일** → 비용 재산정 대상
- 🆕 **작업규칙 18·19·20 신설** — 덮어쓰기 금지 · 브랜치 확인 · 확정값 확인 (전부 실제 사고 기록)
- 🆕 **검수 체크리스트 13·14·15 신설** — 변수 접두사 · 모듈 default 금지 · 모듈 provider 금지
- 🆕 **막힌 항목 9~13 신설** — **Redis 미설계** · **App 노드 메모리(MaxRAMPercentage 75%)** · **ALB Idle Timeout(SSE)** · **빌드 EC2 정체** · DNS 서브도메인
- 🟡 **미확정 2건 표기** — 공통 변수 위치(`common_variables.tf` 제안) · `.auto.tfvars` 자동 로드 제안

**09-14 (2차 · 모듈화·동기화)**
- 🔄 **모듈화 전략 반전** (파트장) — `modules/` **사용함**. 이전 판 *"모듈화 안 함"* 폐기
- 🆕 **`moved` 블록 절차 신설** — 없이 이관하면 **43개 리소스 destroy+create**. 작업규칙 **15·16** 신설
- 🆕 **작업규칙 17 신설** — 과금 리소스 9/17 까지 `plan` only · **9/18 일괄 apply**
- ✅ **`env_short` 삭제** — 설계서 최종본이 리소스 접두사도 `staging` 으로 통일. `jangin-stg-*` → **`jangin-staging-*`**
- 🟡 **DNS 서브도메인(`stg.` vs `staging.`) 은 별개 축** — 파트장 확인 대기 (자동 변경하지 않음)
- 🔴 **⑧ 에 EBS CSI Driver 애드온 명시** — 명수님 gp3 StorageClass 의 선행조건. 빠지면 **CNPG PVC `Pending`**
- 🆕 **배포 완료 리소스 ID 표** 신설 (인계 문서 재료)
- 🆕 **설계서 ↔ 코드 차이 4건** 신설 (파트장 확인 요청)
- 🆕 막힌 항목 **6~9 추가** — 변수파일 A/B · staging·prod 운영 방식 · 공용 ECR State · 설계서 차이
- 레포에 **`k8s/` · `platform/` 유입** (CN 박명수) — 인프라 수정 금지 영역으로 표기
- 로컬 동기화 완료 — 브랜치 5개 정리 · `terraform plan` = `No changes.` 검증

**09-10 → 09-14 (1차)**
- 디렉토리 경로 정정: `envs/` → **`environments/`** (레포 실물 기준)
- 🆕 **환경 분리 전략 확정** (파트장) — 폴더 분리 · 각 폴더 개별 apply · prod 기준 작성
- State 백엔드 확정값: `jangin-infra-s3-tfstate` / `jangin-infra-ddb-tfstate-lock` + TLS 강제 정책
- `.terraform.lock.hcl` **커밋**으로 전환 (3플랫폼 해시 필수)
- 작업규칙 **14 신설**(staging 반영 명시) · 규칙 10 보충(`NodePool` 은 과금 리소스에만)
- IaC ①~④ 완료 — 43개 리소스 · $0 · PR #3~#6

**09-09 → 09-10**

| 구분 | 내용 |
|---|---|
| 🔄 **전제 변경** | NAT Instance→**Gateway**(`sg-nat` 소멸) · Modal→**EKS GPU 직접** · 크레딧 **$0** · System **t3.medium×2**/App **×1** · 운영 **분산 11일** |
| ✅ **확정** | SSO URL · **IRSA 6종** · health **`/healthz`** · **ECR 단일 레포** · **Parameter Store 3단** · **App limits 기준** · **CORS 전값** · **`gpu-model` 라벨** · **NVMe B안** · **staging FE·BE 배포** · **AI 포트 8000** · 네이밍 규칙 |
| 🆕 **신설** | **`sg-eks-gpu`** · `s3-logs` **4용도 prefix** · **`NodePool` 태그** · **VPC Flow Logs** · configtree · Cost Explorer+Athena |
| 🟢 **결론** | **ECR Interface Endpoint 미도입** (NAT $2.95 vs Endpoint $10.28) · **Kubecost 미도입** |
| 🔴 **신규 안건** | **CloudFront OAC** (보안 권고, **비용도 더 저렴**) · ECR 태그 3중 충돌 · 메일 SMTP 세부 · 스테이징 GPU · **예산 98.8%** |