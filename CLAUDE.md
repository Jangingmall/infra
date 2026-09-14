# 장인몰 인프라 — 클라우드 인프라 파트 (`CLAUDE.md`)

> kt cloud TECH UP 2기 3팀 "삼성가고싶어요" 통합프로젝트 · 서비스 **장인몰**
> Claude Code가 매 세션 자동으로 읽습니다. **결정사항 위주로 짧게 유지하세요.**
> 기준: **통합프로젝트 Context 2026-09-10** + **팀 컨텍스트 v0.6** + **2.6.1 v0.4** + **비용 보고서 v1.0**
> 최종 갱신 **2026-09-10** (이전판 09-09)

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
| 1 | **이미지 버킷 — CloudFront OAC vs 공개** | 파트장 + 보안 | S3 버킷 정책 · **ACM은 `us-east-1`** |
| 2 | **ECR 태그 규칙** (BE `sha-` vs 다정님 `staging-`/`prod-`) | CN+다정+BE | ECR 레포·IAM 정책 |
| 3 | **메일 SMTP 세부** ("google email"만 회신) | BE | 아웃바운드 포트·시크릿 |
| 4 | **App `requests` 구체값** | BE | 롤링 배포 가능 여부 |
| 5 | **AI 컨테이너 이미지·모델 배포 경로** | AI | NAT 처리료 $13 |

> 위 값이 안 나온 상태에서 **임의값으로 채우지 말 것.** `variable` + `TODO` 주석으로 남기고 진행.

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
| **DNS** | apex `midam.store` → Vercel / `api.midam.store` → ALB<br>**`stg.midam.store`** · **`api.stg.midam.store`** |
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
이미지조회 : 브라우저 → S3 `products/` 직접  🟡 CloudFront 검토 중
관리      : Admin → SSM Session Manager (Bastion 없음, SSH 22 차단)
🔴 차단   : Data→인터넷 ✕ / ALB→9090 ✕ / GPU→DB ✕ / Staging→Prod ✕
```

---

## 🔧 네트워크 확정값 — Terraform 작성 시 이 값

| 환경 | VPC | CIDR |
|---|---|---|
| **prod** | `jangin-prod-vpc` | **`10.0.0.0/16`** |
| **staging** | `jangin-stg-vpc` | **`10.1.0.0/16`** |

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
일반:  jangin-<env>-<resource>
       jangin-prod-vpc / jangin-stg-subnet-public-a / jangin-prod-sg-db

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
- ✅ 컨테이너 `eclipse-temurin:25-jre`
- 🟠 **메일 = "google email"** — SMTP 종류·발신주소·인증방식 미상

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
| **14** | 🆕 **prod 를 고치면 staging 반영 여부를 PR 본문에 명시** — 폴더 복사 방식이라 자동 반영되지 않음 |

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
| **9/10 (목)** | 🔴 **IaC 착수** · Phase2 보완 제출 |
| 9/11~13 | EKS · 노드그룹 · IRSA · S3 · ALB |
| **9/14** | **운영환경 가동 시작** (운영 시작일) |
| 9/15~17 | IAM 한시적 admin 회수 |
| **9/18** | 🔴 **인프라 전체 가동완료** (멘토 강조) |
| **9/21~23** | 스테이징 제공(DAST) · FE/BE 개발완료 · QA |
| 9/22 (화) | 인프라 멘토링 3차 |
| 9/24~27 | **추석 연휴 + 주말** — 운영 중단 |
| 9/28~30 | 최종 검증 |
| 10/1 | 문서 작업 집중 |
| **10/2 17:00** | 결과물 제출 · 운영환경 종료 |
| **10/6** | 최종 발표 (30분 + Q&A 20분) |

**운영 스케줄**: 09:00~18:00 (하루 9시간) · 운영일 11일 · 달력 유지일 17일

### IaC 착수 순서

```
① Terraform State (S3 + DynamoDB Lock)   ← CLI 수동 생성
② VPC · 서브넷 6개 · 라우팅 · IGW          ← 무료
③ Security Group 4종 (sg-eks-gpu 포함)     ← 무료
④ S3 Gateway Endpoint                      ← 무료
⑤ NAT Gateway + EIP(prevent_destroy)       ← 🔴 유료
⑥ EKS 클러스터 + OIDC Provider
⑦ 노드그룹 (System/App/DB/GPU×2 — GPU는 desired=0)
⑧ KMS CMK + Parameter Store + IRSA 6종
⑨ S3 버킷 5종 (prefix·lifecycle·CORS)
⑩ ALB · WAF · Route53 · ACM
```

> 💡 **②③④는 전부 무료.** 9/14 전에 만들고 지우고 다시 만들어도 $0이라, **여기서 코드를 검증해두면 유료 리소스를 붙일 때 실패 확률이 크게 줄어듭니다.**

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

### 디렉토리 구조 (2026-09-14 정정)

```
infra/
├── CLAUDE.md · .claude/settings.json
├── .gitignore · CONVENTION.md · README.md
├── scripts/bootstrap-tfstate.sh        ← State 백엔드 부트스트랩 (CLI)
└── terraform/
    ├── environments/prod/              ← 평평하게(flat) 작성
    │   ├── versions.tf · backend.tf · providers.tf
    │   ├── locals.tf · variables.tf · outputs.tf
    │   ├── vpc.tf · security_group.tf · endpoints.tf · nat.tf
    │   ├── .terraform.lock.hcl         ← ✅ 커밋 (3플랫폼 해시)
    │   └── terraform.tfvars            ← 🔴 커밋 금지
    ├── environments/staging/           ← prod 복사 + 값만 변경
    └── modules/                        ← 🗑 사용하지 않음 (빈 껍데기 유지)
```

🔴 **경로는 `environments/` 입니다** — 이전 판의 `envs/` 는 오기였습니다. 레포 실물 기준.

⚠️ **`.terraform.lock.hcl`은 커밋합니다.** provider 버전을 팀원 전원이 동일하게 쓰게 하는 파일이라, 빼면 사람마다 다른 provider로 plan이 갈립니다.
커밋 전 반드시 멀티 플랫폼 해시를 넣습니다 — `terraform providers lock -platform=darwin_arm64 -platform=darwin_amd64 -platform=linux_amd64`. 안 하면 인텔 맥·GitHub Actions(linux_amd64)에서 깨집니다.

### 환경 분리 전략 ✅ **확정 (2026-09-14 파트장)**

| 항목 | 방식 |
|---|---|
| 코드 분리 | 🔴 **폴더 분리** — git branch 아님. **각 폴더에서 개별 `apply`** |
| State 분리 | **같은 버킷 · `key` 경로만 분리** — `prod/terraform.tfstate` / `staging/terraform.tfstate` |
| 작성 순서 | **prod 완성 → staging으로 복사 → 값만 변경** |
| 모듈화 | 🔴 **하지 않음** (이전 판의 "모듈화는 staging 만들 때" 폐기) |
| 목적 | 9/21 보안팀 DAST 검수 기간에 staging 제공 |

**staging 복사 시 바꿀 값 — 이것만 다릅니다**

| 파일 | 항목 | prod | staging |
|---|---|---|---|
| `backend.tf` | `key` | `prod/terraform.tfstate` | `staging/terraform.tfstate` |
| `variables.tf` | `env` | `prod` | `staging` |
| `variables.tf` | `vpc_cidr` | `10.0.0.0/16` | `10.1.0.0/16` |
| `variables.tf` | `subnet_cidrs` | `10.0.*` | `10.1.*` |
| `variables.tf` | `cluster_name` | `jangin-prod-eks-cluster` | `jangin-stg-eks-cluster` |

> 🔴 **`env` 값과 이름 접두사가 다릅니다.**
> Parameter Store 경로·State key 는 **`staging`**(IF_04 BE 회신 확정)이고,
> 리소스 이름 접두사는 **`stg`**(`jangin-stg-vpc` — 네트워크 확정값)입니다.
> `locals.tf` 에서 분리해야 합니다:
> ```hcl
> env_short = var.env == "staging" ? "stg" : var.env
> name      = "${var.project}-${local.env_short}"   # jangin-prod / jangin-stg
> ```
> 이걸 안 하면 staging 리소스가 `jangin-staging-vpc` 로 생겨 IAM Deny 접두어(`jangin-stg-*`)에서 빠집니다.

> 🔴 **drift(두 환경이 갈리는 것) 주의**
> 복사 방식이라 **prod를 고치면 staging에 손으로 반영**해야 합니다. 빠뜨리면 보안팀 요구
> *"prod와 동일한 환경에서 검수해야 의미가 있다"* 가 깨집니다.
> - prod PR 본문에 **"staging 반영 필요 여부"** 를 체크 항목으로 넣습니다
> - 동기화 확인: `diff -r -x '.terraform*' terraform/environments/prod terraform/environments/staging`
> - 기대 diff: 위 표의 5개 항목뿐

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
| 9 | **`NodePool` 태그 있는가** |
| 10 | **NAT EIP에 `prevent_destroy` 있는가** |

💡 **plan 출력**: `Plan: N to add, 0 to change, 0 to destroy`
**`to destroy`가 0이 아니면 절대 apply하지 마세요.**

---

## 평가 기준 (클라우드·보안 그룹)

**전문성 30**(환경설계·비용통제) / **차별성 30**(운영·보안 리스크 인식) / **완성도 30**(**실제 동작 여부** + 타 직군 인계 문서) / **발표 10**(**비전문가도 이해 가능하게**)

→ 제안할 때 **어느 항목 점수를 노리는지 밝힐 것.**

---

## 변경 이력

**09-10 → 09-14**
- 디렉토리 경로 정정: `envs/` → **`environments/`** (레포 실물 기준)
- 🆕 **환경 분리 전략 확정** (파트장) — 폴더 분리 · 각 폴더 개별 apply · **모듈화 안 함** · prod 복사 방식
- 🔴 `env`(=`staging`) 와 이름 접두사(=`stg`) 분리 필요 — `locals.env_short`
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