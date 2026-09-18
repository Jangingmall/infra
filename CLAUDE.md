# 장인몰 인프라 — 클라우드 인프라 파트 (`CLAUDE.md`)

> kt cloud TECH UP 2기 3팀 "삼성가고싶어요" 통합프로젝트 · 서비스 **장인몰**
> Claude Code가 매 세션 자동으로 읽습니다. **결정사항 위주로 짧게 유지하세요.**
> 기준: **통합프로젝트 Context 2026-09-14** + **팀 컨텍스트 v0.8** + **네트워크·계정 설계서 최종본(9/14)** + **모듈화 전략 B안(9/15 19:21 파트장 최종)** + 🆕 **비용 재산정 v2.0(9/17 창원)** + **엣지·S3 버킷 설계서(9/16 파트장)** + 🆕 **인터페이스 명세서 v0.6(9/17)**
> 최종 갱신 **2026-09-17** (이전판 09-16)
>
> 🔴 **현재 AWS 상태: 여전히 리소스 없음.** ②③④ 는 코드만 `main` 에 머지(PR #18)됐고 **apply 는 9/18 일괄**입니다.
> ✅ **예외 — ① State 백엔드는 살아 있고, 9/16 에 SSE-KMS(CMK)로 전환**했습니다. 「배포 리소스 현황」 참조.
>
> 🔴 **9/17 기준 코드는 ⑧ 일부까지 작성 완료.** PR #35(EKS 결정)·#36(노드그룹 ⑦)·#37(애드온) 이 **스택 구조**로 올라가 있습니다.
> `Plan: 66 to add, 0 to change, 0 to destroy` 까지 확인했고 **apply 는 하지 않았습니다**(규칙 17).
> 🔴 **신준한 9/17·9/18 연속 부재** — 9/18 프로비저닝은 파트장님 주도입니다. 「일정」의 인수인계 항목 참조.

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
| 4 | **AI 컨테이너 이미지·모델 배포 경로**<br>🔄 09-16: 명수님 PR #24 의 AI 이미지가 **임시 값** — *"실제 ECR 주소·Digest 로 교체 필요"* | AI + CN + 창원 | NAT 처리료 $13 · **Pod 가 안 뜸** |
| 5 | **staging / prod 운영 방식** (가)순차·(나)staging축소·(다)prod단일 | 파트장 + 그룹장 | **동시 운영은 예산 2배로 불가** |
| 6 | **공용 ECR State 위치** — 🔴 현재 `ecr_enabled = false` **양쪽 다 꺼져 있음**<br>🔄 09-16 창원님 제안: *"동일 digest 승격이라 환경별 분리 시 승격 모델이 깨짐 → **prod state 단일 생성 + staging 공유**"* → 인프라 동의. **파트장 확정 대기**<br>🔴 **지금 정해야 함** — state 간 이동은 `moved` 로 안 되고, Immutable 태그라 재생성 시 BE 이미지 소실 | 창원 + 파트장 | **BE가 `docker push` 못 함** |
| 7 | **최종 설계서 ↔ 코드 차이 4건** (아래 「설계서 차이」) | 파트장 | ⑦⑧ 코드 작성 |
| ~~8~~ | ~~EKS 버전 · 인증 모드 · 엔드포인트 공개~~ | — | ✅ **9/17 해소** (아래) — 1.35 / `API` / **(B) public+IP제한 → 9/21 private only** |
| **9** | 🔄 **Redis 배치** — 09-17 **k8s Pod 로 확정**(ElastiCache 미사용). 명수님: *"redis는 app 노드에 띄우는 게 좋긴 한데 그러면 large를 써야 할 것 같다"*<br>🔴 **남은 것: 최종 배치 노드** — 제 v0.6 통보안은 **System 노드 512Mi**, 명수님은 **App 노드** 선호 | CN(명수) + 인프라 | ⑦ 노드 사양은 **이미 App `t3.medium`×2 로 반영**했으므로 apply 는 막지 않음 |
| ~~10~~ | ~~App 노드 메모리(OOM 위험)~~ | — | ✅ **9/17 해소** — App 노드가 **`t3.medium` × 2** 로 늘어 Pod 2개가 **노드 1대씩** 쓰게 됨. 한 노드에 2개가 몰리던 구조가 사라짐 |
| **11** | 🆕 **ALB Idle Timeout** — BE가 **SSE + AI 응답 Streaming** 사용. 기본 60초면 끊김 | 인프라(⑩) | SSE 연결 유지 |
| **12** | 🆕 **`jangin-staging-build` EC2 정체** — 다정님 SSM 안내에 등장. 기존 설계엔 **Bastion·빌드 EC2 없음** | 다정 + 파트장 | 신규 리소스면 **비용 미산정** |
| ~~13~~ | ~~DNS 서브도메인 `stg.` vs `staging.`~~ | — | ✅ **9/16 해소** (아래) |
| ~~14~~ | ~~AI ServiceAccount 이름 변경~~ | — | ✅ **9/16 해소** — 두 Deployment 가 `ai-worker-sa` 를 **공유**. IRSA 6번 그대로 유효 |
| **15** | 🆕🔴 **NetworkPolicy egress 예외 — 인프라가 값 5종을 CN 에 줘야 함** (PR #24 명시 요구) | **인프라** → CN | 🔴 **DB·Backend·AI 발신 정책을 영영 연결 못 함.** 보안팀 조건 #1 미충족 |
| ~~16~~ | ~~VPC CNI NetworkPolicy 미활성화~~ | — | ✅ **9/17 해소** — PR #37 `modules/eks_addons` 에서 `enableNetworkPolicy = "true"` 로 켬. ⚠️ **문자열** 이어야 함(boolean 거부) |
| **17** | 🆕🔴 **무효 리소스 ID 가 타 직군 문서에 살아 있음** — `vpce-02f0b40…` 등 9/15 destroy 된 ID | **인프라** (즉시 공지) | 잘못된 값으로 설계·구현이 진행됨 |
| **18** | 🆕🔴 **앱용 KMS CMK 담당자 미정** — 다정님 PR #32 의 `kms:Decrypt` statement 가 `#resources = [var.aws_kms_key.shared.arn]` 로 **주석 처리**돼 있고, 가리킬 CMK 가 레포에 없음<br>⚠️ **State 용 CMK(`alias/jangin-infra-s3-tfstate`)와 별개 키**입니다 | 파트장 + 다정 | 🔴 **9/18 apply 가 `MalformedPolicyDocument` 로 실패.** `plan` 에서는 안 잡힘 |
| **19** | 🆕🔴 **⑩ 엣지 모듈이 환경에서 호출되지 않음** — `modules/{alb,waf,cloudfront,acm_alb,acm_cloudfront}` 는 있는데 `environments/*/` 에 호출 파일(`alb.tf` 등)이 없음 | **파트장**(⑩ 영역) | 🔴 **apply 해도 ALB·WAF·CloudFront 가 생기지 않음.** `plan` 으로 절대 못 잡음(없는 코드는 차이가 아님) |
| **20** | 🆕 **팀원 공인 IP 미수집** — `eks_public_access_cidrs` | 전원 → 인프라 | 🔴 **PR #35 의 precondition 으로 `plan` 자체가 실패** |
| **21** | 🆕 **예산 한도 500,000원의 범위** — 클라우드/보안 그룹 한도인지 8개 직군 전체 한도인지<br>FE Vercel $20 · 보안 LLM 10,000원이 같은 한도면 여유가 줄어듦 | PM + 그룹장 | 80.4% 라는 수치의 의미가 달라짐 |
| **22** | 🆕🔴 **산출물3 초본 ↔ 확정 설계 불일치 10건** (Aurora vs CNPG · Karpenter/KEDA · Modal · CloudFront 미도입 · console-first · Multi-AZ · 크레딧 $150 등) | 다정 + 인프라 | **평가가 "실제 동작 여부"를 보므로 문서와 실물이 다르면 신뢰 손실** |

> 위 값이 안 나온 상태에서 **임의값으로 채우지 말 것.** `variable` + `TODO` 주석으로 남기고 진행.

### ✅ 9/17 해소된 것

| 항목 | 결론 |
|---|---|
| **EKS 3대 결정** | ✅ **버전 `1.35` · 인증 `API` · 엔드포인트 (B) public(팀원 IP 제한)+private**<br>🔑 **9/21 부터 (C) private only 로 전환** — 파트장: *"B안으로 작성해뒀습니다. 9/21부터 private로 전환하는 방식이 좋을 것 같아요"*<br>경위: 9/16 에 (C) private only 로 정해졌으나, ① 제가 *"3대 결정 전부 비가역"* 이라고 **잘못 안내**한 점 정정(엔드포인트는 **몇 분이면 전환 가능**) ② **Helm 최초 설치(ArgoCD·CNPG·Rollouts·Secrets Store CSI)가 막힌다**는 걸림돌 발견 → 재검토 안건 제출 → 파트장 수용<br>🔴 **남은 것: 팀원 공인 IP 수집**(막힌 항목 20) |
| **Karpenter / KEDA** | ✅ **미사용 확정** — 파트장: *"안 쓰는 방향으로 해야 할 것 같아요. 서버 올리고 기능 확인하기도 힘들 것 같아서"*<br>🔴 **Phase3 산출물 5번(AutoScaling 시연)은 HPA 만 남습니다** |
| **노드 사양** | 🔄 **변경 확정** — System `t3.medium`×1 + **`t3.large`**×1 / App `t3.medium`**×2** (Redis 배치 사유). 아래 「노드 구성」 |
| **VPC CNI NetworkPolicy** | ✅ **PR #37 에서 활성화** (막힌 항목 16) |
| **비용 재산정** | ✅ **v2.0 (창원님 9/17)** — **401,756원 / 500,000원 = 80.4%**. 기존 98.8% 에서 크게 완화. 아래 「비용」 |
| **버킷 lifecycle** | ✅ 파트장 확정. 🟡 다정님 의견 — *vpc-flow 14일 / loki 7일은 짧으니 20일 정도* (반영 여부 미정) |

### ✅ 9/16 해소된 것

| 항목 | 결론 |
|---|---|
| **DNS 서브도메인 `stg.` vs `staging.`** | ✅ **`stg.` 확정** (9/16 파트장 「엣지·S3 버킷 설계서」).<br>`midam.store`→Vercel · `api.midam.store`→ALB · **`stg.midam.store`**→Vercel staging · 🆕 **`api.stg.midam.store`**→staging ALB · 🆕 **`img.midam.store`**→CloudFront<br>⚠️ **리소스 이름 접두사는 그대로 `staging`** 입니다. DNS 와 리소스명은 별개 축이라는 기존 판단이 유지됐습니다 |
| **이미지 CDN 도메인** | ✅ **`img.midam.store`** 확정 → FE `next.config.js` 통보 대상 (인터페이스 명세서 IF_11) |
| **S3 버킷 구성** | ✅ **5종 → 7종** 으로 변경 (9/16 파트장). 아래 「S3 버킷」 참조 |
| **State 암호화 SSE-KMS(CMK)** | ✅ **9/16 전환 완료.** 파트장 지적 반영 — PR `fix/tfstate-kms-encryption`. 아래 「배포 리소스 현황」 |
| **CNPG 노드 배치(Taint/Toleration)** | ✅ **명수님 PR #21 에 반영 완료.** 인프라가 요청한 내용이 그대로 들어감 → ⑦ 사양이 고정됨 (아래 「노드 구성」 참조) |
| **네트워크 모듈 구조** | ✅ **`modules/nat` 분리** (9/16 파트장 리뷰). 「디렉토리 구조」 참조 |

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
| IaC | **Terraform** (State: 전용 S3 + DynamoDB Lock — **CLI 수동 생성 승인**)<br>🔄 09-16: State 암호화 **SSE-KMS(CMK) 전환 완료**. 키는 `alias/jangin-infra-s3-tfstate`<br>🔴 이 CMK 는 **Terraform 이 관리하지 않습니다** — ⑧ CMK 로 쓰면 순환 의존 |
| 클라우드 | **AWS 단일** |
| 리전 | **`ap-northeast-2` (서울)** |
| 계정 | 공용계정 1개 + IAM Identity Center. **SSO Start URL**: `https://d-9b675a5254.awsapps.com/start` |
| 오케스트레이션 | **EKS** 🔄 **09-17 3대 값 확정**<br>버전 **`1.35`** · 인증 모드 **`API`**(구 `aws-auth` ConfigMap 미사용) · 엔드포인트 **public(팀원 IP 제한) + private**<br>🔑 **9/21 부터 private only 로 좁힘** — 구축기와 운영기의 위험이 다르다는 판단. **전환 시점·근거·전후 설정을 기록해야** 의미가 있습니다 |
| **오토스케일링** | 🔄 **09-17: Karpenter · KEDA 미사용 확정.** **HPA 만** 사용<br>사유(파트장): 남은 기간에 *"서버 올리고 기능 확인하기도 힘들"* — 🔴 Phase3 산출물 5번에 영향 |
| **환경 분리** | **staging / prod 별도 클러스터 · 별도 VPC** (Peering 없음) |
| **NAT** | ✅ **NAT Gateway** (AZ-a 단일 + **EIP 고정**) — ~~NAT Instance~~ 폐기 |
| LB | **ALB (target-type `ip`)** + **AWS WAF** · Pod Readiness Gate 병행 |
| **DNS** ✅ | 🔄 **09-16 전부 확정** (파트장 「엣지·S3 버킷 설계서」)<br>`midam.store` → Vercel (FE) · `api.midam.store` → ALB (BE)<br>**`stg.midam.store`** → Vercel staging · 🆕 **`api.stg.midam.store`** → staging ALB<br>🆕 **`img.midam.store`** → CloudFront (상품 이미지 CDN)<br>⚠️ **DNS 는 `stg.` / 리소스 이름 접두사는 `staging`** — 별개 축입니다. 통일하지 마세요 |
| **DB** | **CloudNativePG** — Primary 1 + Replica 2 |
| **캐시** 🆕 | 🔄 **09-17: Redis 를 k8s Pod 로 운영 확정** (ElastiCache 미사용 — 별도 과금·VPC 리소스 회피)<br>🔴 **배치 노드 미확정** — 인프라 통보안은 System 노드, CN 은 App 노드 선호 (막힌 항목 9)<br>BE 요구 키: `redis-host` · `redis-port` |
| 레지스트리 | ECR — **단일 레포 `jangin-app` + 동일 아티팩트 승격** · **Immutable** |
| **시크릿** | Parameter Store **`/{env}/{team}/{key}` (3단)** + KMS CMK<br>**CSI Driver → 볼륨 마운트 → Spring `configtree`** (Secret Sync 미사용) |
| **AI 런타임** | **EKS GPU 직접** — g6e.xlarge(이미지·SGLang) + g4dn.xlarge(챗봇·Ollama)<br>🔄 09-16: 명수님 PR #24 가 Deployment·Service 를 **`ai-sglang`(L40S) / `ai-ollama`(T4)** 로 분리<br>✅ 09-16 확인: 두 Deployment 가 **`ai-worker-sa` 를 공유** → IRSA 6번 그대로 유효 |
| S3 | 🔄 **09-16: 5종 → 7종** — images / returns / backup / models / logs + 🆕 **access** + 🆕 **waf-logs** |
| CI/CD | GitHub Actions → ECR → ArgoCD → EKS |
| 레포 | **`infra` 단일** + `terraform/`·`k8s/`·`argocd/` |
| 모니터링 | Prometheus + Grafana + **Loki(S3 백엔드)** — **Kubecost 미도입** |
| **비용 분석** | **Cost Explorer + Athena(CUR)** |

### 트래픽 경로 (내 담당 영역)

```
인바운드  : 사용자 → Route53(DNS 조회) → WAF → ALB → App Pod : 443→8080 (/healthz)
앱↔DB     : App Pod ↔ CNPG Pod : 5432                      (양방향)
앱→AI     : App Pod → GPU Pod : 8000                       (클러스터 내부)
             🔄 09-16 PR #24: 대상이 2개로 분리됨
             ├─ ai-sglang Service : 8000   (L40S · 이미지)
             └─ ai-ollama Service : 8000   (T4  · 챗봇)
모니터링   : Prometheus → App Pod : 9090                     (클러스터 내부만)
아웃바운드 : 모든 노드 → NAT Gateway(EIP 고정) → IGW : 443
             ├─ 토스페이먼츠(PG) · 카카오/구글/네이버(OAuth) · 스마트택배
             ├─ Google SMTP : 587/465
             └─ ECR · STS · EC2 API
             🔴 STS 는 IRSA 의 생명줄 — NetworkPolicy egress 예외에 반드시 포함 (막힌 항목 15)
S3        : 노드 → S3 Gateway Endpoint (NAT 미경유 · 무료)
이미지조회 : 브라우저 → CloudFront(OAC) → S3 `products/`   ✅ 9/15 확정 · BPA 유지
             🆕 09-16: CDN 도메인 = img.midam.store
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

> 🔴 **네이밍 규칙의 유일한 예외 (09-16 신설)**
> ```
> aws-waf-logs-logs-jangin-{env}     ← WAF 로그 버킷
> ```
> AWS 가 **WAF 로그 대상 버킷 이름은 `aws-waf-logs` 로 시작해야 한다**고 하드 제약을 겁니다.
> **`jangin-` 으로 고치면 WAF 로깅이 조용히 멈춥니다.** 이름을 바꾸기 전에 이 문단을 확인하세요.

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

## 노드 구성 ✅ 확정 (🔄 09-17 사양 변경 · PR #36 반영 완료)

```
[구]  System t3.medium × 2        /  App t3.medium × 1
[신]  System t3.medium×1 + t3.large×1  /  App t3.medium × 2      ← 09-17
```

**변경 사유**: Redis 배치. 명수님 — *"redis는 app 노드에 띄우는 게 좋긴 한데 그러면 large를 써야 할 것 같다. system node도 한 대는 large로 썼으면 좋겠다"*
→ 부수 효과로 **막힌 항목 10(App OOM 위험)이 함께 해소**됐습니다. App Pod 2개가 노드 1대씩 쓰게 되기 때문입니다.

| 노드그룹 키 | 인스턴스 | desired / min / max | 과금 유형 | 워크로드 |
|---|---|---|---|---|
| **`system-md`** | `t3.medium` | 1 / 1 / 2 | ON_DEMAND | Prometheus·Grafana·Loki·ArgoCD·ALB Controller |
| 🆕 **`system-lg`** | **`t3.large`** | 1 / 1 / 2 | ON_DEMAND | 위 + 여유 (명수님 요청) |
| **`app`** | `t3.medium` | 🔄 **2** / 2 / 3 | ON_DEMAND | Backend Pod (+ Redis 배치 후보) |
| **`db`** | `t3.small` | 🔴 **3 / 3 / 3** | 🔴 **ON_DEMAND 고정** | CNPG Primary 1 + Replica 2 |
| **`gpu-a`** | **`g6e.xlarge`** (L40S 48GB) | 🔴 **0 / 0 / 1** | — | 이미지·텍스트 (SGLang) |
| **`gpu-b`** | **`g4dn.xlarge`** (T4 16GB) | 🔴 **0 / 0 / 1** | — | 챗봇 (Ollama) |

> 🔑 **`desired/min/max` 를 표에 적어두는 이유**: 대수만 적으면 나중에 누가 `min_size` 를 낮춰도
> "표대로다" 라고 생각하게 됩니다. **DB 의 `min_size=3`** 은 대수가 아니라 **제약**이라 여기 같이 씁니다.

🔴 **PR #36 에서는 이 세 가지를 주석이 아니라 `precondition` 으로 강제했습니다.**

| # | 조건 | 어기면 |
|---|---|---|
| 1 | `min_size ≤ desired_size ≤ max_size` | 값 뒤집힘 |
| 2 | `workload-type=db` 면 `min_size ≥ 3` | CNPG Pod 1개가 **영구 `Pending`** |
| 3 | `workload-type=db` 면 `ON_DEMAND` | Spot 회수 시 **그 Pod 가 영영 못 돌아옴** |

> 💡 **왜 주석이 아니라 코드인가** — 주석은 읽는 사람에게만 작동하고, `precondition` 은 **`plan` 단계에서 실패**시킵니다.
> 비용을 줄이려고 `min_size` 를 낮추는 건 아주 자연스러운 수정이라, 사람 기억에 맡기면 언젠가 반드시 일어납니다.

### 🆕🔴 DB 노드그룹 — 09-16 제약 확정 (명수님 PR #21)

명수님이 `k8s/base/database/cluster.yaml` 에 아래를 넣으셨고, 이게 ⑦ 사양을 고정합니다.

```yaml
spec:
  affinity:
    nodeSelector:
      workload-type: db          # ← 라벨 키:  workload-type
    tolerations:
      - key: workload            # ← Taint 키: workload   (서로 다름. 정상입니다)
        value: db
        effect: NoSchedule
    enablePodAntiAffinity: true
    topologyKey: kubernetes.io/hostname
    podAntiAffinityType: required   # 🔄 preferred 에서 변경됨
```

**⑦ 에서 반드시 이 값으로 만들어야 합니다**

```hcl
labels = { "workload-type" = "db" }                                  # Pod 가 노드를 고르는 쪽
taint  = { key = "workload", value = "db", effect = "NO_SCHEDULE" }  # 노드가 Pod 를 막는 쪽
```

⚠️ **Label 키와 Taint 키가 다릅니다.** 둘은 별개 메커니즘이라 달라도 동작하며,
GPU 규약(`workload-type=gpu` 라벨 + `nvidia.com/gpu` Taint)과도 일관됩니다. **통일하지 마세요.**

🔴 **`podAntiAffinityType: required` 가 만든 제약**

`required` + `topologyKey: hostname` = *"CNPG Pod 3개는 반드시 서로 다른 노드에"* 입니다.
Pod 3개 : 노드 3대 = **여유 0**.

| 항목 | 값 | 안 지키면 |
|---|---|---|
| `desired_size` | **3** | Pod 가 못 뜸 |
| **`min_size`** | 🔴 **3** (2 아님) | 오토스케일러가 1대 줄이는 순간 **Pod 1개 영구 `Pending`** |
| `capacity_type` | 🔴 **`ON_DEMAND`** | **Spot 회수 시 그 Pod 가 영영 못 돌아옴** |

⚠️ **10/1~10/4 노드 내리기 때도** DB 노드를 부분적으로 줄이면 복구 시 Pod 가 안 뜹니다.
**전부 내렸다 전부 올리는** 방식이어야 합니다 (파트장 Q-PL-07 결정과 직결).

> 💡 `required` 는 더 안전해 보이지만 **가용성을 노드 대수에 묶습니다.**
> 실무에선 노드를 Pod 보다 1대 더 두거나 `topologyKey` 를 AZ 단위로 올리는데,
> 우리는 **AZ-a 단일 + 예산 98.8%** 라 둘 다 못 합니다. 잔여 위험으로 기록합니다.

### GPU 노드그룹 — 🔴 `desired_size = 0`으로 생성

9/10 AI팀 방침: *"AI팀 요청 들어올 때까지 GPU 안 띄워도 될 것 같다"*
→ **`min_size=0, desired_size=0`** 으로 만들어두면 **요청 시 값 하나로 즉시 기동**, 그전까지 **$0**. 9/18 가동완료는 "구성 완료·기동 대기"로 충족.

```
Label:  workload-type=gpu, node-lifecycle=spot
        gpu-model=l40s  (GPU-A)  /  gpu-model=t4  (GPU-B)
Taint:  nvidia.com/gpu=true:NoSchedule   (양쪽 동일)
```

🔴 **`gpu-model` 라벨이 없으면** 챗봇 Pod가 비싼 g6e에 뜨거나 이미지 Pod가 T4에서 OOM.

### GPU 스토리지 — 🔄 **09-17 정정: 루트 EBS 상향으로 진행** (구: 로컬 NVMe)

| | 구 방침 (09-10~09-16) | 🔄 신 방침 (09-17 · PR #36) |
|---|---|---|
| 방식 | 로컬 NVMe 를 containerd 데이터 루트로 | **루트 EBS 상향** |
| 크기 | g6e 250GB / g4dn 125GB (Instance Store) | **g6e 200GB / g4dn 120GB (gp3)** |
| 구현 | Launch Template **userData** 필요 | `disk_size` 한 줄 |

🔴 **바꾼 이유 — 검증 불가능한 코드를 부재일에 넣지 않기 위해서입니다.**

- AL2023 은 부팅 스크립트가 **`nodeadm` 기반**이라 기존 AL2 예제가 그대로 안 통합니다.
- userData 는 **클러스터가 떠야 테스트가 됩니다.** 지금은 클러스터가 없습니다.
- 실패하면 증상이 *"노드가 `NotReady` 인데 이유가 안 보임"* 이고, 🔴 **9/18 에 제가 없습니다.**
- 비용 차이는 약 **$6** — 예산이 80.4% 로 내려온 상황에서 감수할 만한 금액입니다.

> 💡 **트레이드오프를 정확히 적으면**: NVMe 는 **빠르고 공짜**지만 노드가 죽으면 **모델 캐시가 사라져 재다운로드**(NAT 처리료)가 발생합니다.
> EBS 는 **느리고 유료**지만 **재부팅을 견디고 설정이 단순**합니다.
> 지금 우리에게 부족한 자원은 돈이 아니라 **검증할 시간**이라 EBS 를 골랐습니다.
> 🔄 **되돌릴 수 있는 결정입니다.** 구축이 안정되면 별도 PR 로 NVMe 전환을 재검토합니다.

---

## IRSA 6종 ✅ 확정

| # | ServiceAccount | IAM Role | 권한 |
|---|---|---|---|
| 1 | `kube-system:ebs-csi-controller-sa` | `jangin-{env}-irsa-ebs-csi` | EBS 볼륨 (없으면 **CNPG Pod `Pending`**) |
| 2 | `kube-system:aws-load-balancer-controller` | `jangin-{env}-irsa-alb-controller` | ALB 생성 (없으면 **Ingress 만들어도 ALB 안 생김**) |
| 3 | **`app:backend-sa`** | `jangin-{env}-irsa-backend` | Parameter Store + `kms:Decrypt` + **`kms:GenerateDataKey`** |
| 4 | **`database:cnpg-backup-sa`** | `jangin-{env}-irsa-cnpg` | S3 백업 + **`kms:GenerateDataKey`** |
| 5 | **`monitoring:loki-sa`** | `jangin-{env}-irsa-loki` | `s3-logs` 접근 |
| 6 | 🔴 **`ai:ai-worker-sa`** — **09-16 실물과 불일치 가능** | `jangin-{env}-irsa-ai` | `s3-models` 최소권한 |
| — | ~~`secrets-store-csi-driver`~~ | **만들지 않음** | Workload SA가 직접 보유 |

> ⚠️ **OIDC Provider 등록이 선행조건.** 빠뜨리면 `sts:AssumeRoleWithWebIdentity` 오류가 나는데 원인이 잘 안 드러남
> 🔴 **`kms:GenerateDataKey` 누락 시** SSE-KMS 버킷 업로드가 실패하는데, **에러가 KMS인지 S3인지 구분이 안 됨**
>
> 🆕🔴 **09-16: 6번 AI ServiceAccount 재확인 필요** (막힌 항목 14)
> 명수님 PR #24 가 AI 를 **`ai-sglang`(L40S) / `ai-ollama`(T4)** 두 Deployment·Service 로 분리했습니다.
> ServiceAccount 도 분리됐다면 `ai:ai-worker-sa` 하나로는 맞지 않습니다.
> - SA 가 **1개 유지**면 → 기존 IRSA 그대로
> - SA 가 **2개로 분리**면 → IRSA 도 2개(또는 1 Role 에 2 SA trust) 로 가야 함
> 🔴 안 맞으면 AI Pod 가 `s3-models` 를 못 읽고, 에러는 단순 권한 오류로 보여 원인을 찾기 어렵습니다.
>
> 🆕🔴 **09-16: NetworkPolicy egress 에 STS 예외 필수** (막힌 항목 15)
> IRSA 는 Pod 가 **STS 를 호출해 임시 자격증명을 받는 구조**입니다.
> PR #24 가 Backend·DB·AI 발신 차단 정책을 아직 배포에 연결하지 않았는데,
> **STS 예외 없이 연결되면 위 6종이 전부 동시에 죽습니다.** 연결 전 CN 과 반드시 확인.

---

## S3 버킷 **7종** + State 🔄 09-16 변경

> 🔄 **2026-09-16 파트장 「엣지·S3 버킷 설계서」 반영.** 기존 5종 → **7종**.

| 버킷 | 용도 | 공개 | 암호화 |
|---|---|---|---|
| `jangin-{env}-s3-images` | 상품 이미지 | **CloudFront(OAC) 경유만** · BPA 유지 | SSE-S3 |
| `jangin-{env}-s3-returns` | 반품 증빙 | **비공개** | **SSE-KMS(CMK)** |
| `jangin-{env}-s3-backup` | CNPG WAL·백업 | 비공개 | **SSE-KMS(CMK)** |
| `jangin-{env}-s3-models` | AI 가중치 | 비공개 | SSE-S3 |
| `jangin-{env}-s3-logs` | 🔄 **로그 3종으로 축소** — 아래 | 비공개 | **SSE-KMS(CMK)** |
| 🆕 **`jangin-{env}-s3-access`** | **S3 서버 접근 로그 전용** | 비공개 | 🔴 **SSE-S3 (KMS 금지)** |
| 🆕 **`aws-waf-logs-logs-jangin-{env}`** | **WAF 로그 전용** | 비공개 | (기본) |
| `jangin-infra-s3-tfstate` | Terraform State | 비공개 | ✅ **SSE-KMS(CMK) + 버전관리 + TLS 강제** (09-16 전환 완료) |

### 🔴 신설 2종 — 각각 "반드시 이래야 하는" 이유가 있습니다

**① `s3-access` 를 왜 분리하고, 왜 SSE-S3 인가**

S3 서버 접근 로그는 **AWS 의 로그 전송 주체가 직접 버킷에 씁니다.** 이 주체는 우리 CMK 를 쓸 권한이 없어서, **SSE-KMS(CMK) 버킷에는 로그를 남기지 못합니다.**

🔴 **그런데 에러가 나지 않습니다.** 로그가 그냥 안 쌓입니다.
→ 보안팀 검수 때 *"접근 로그가 비어 있다"* 로 발견되는 전형적인 함정입니다.
→ 그래서 **접근 로그만 별도 버킷 + SSE-S3** 로 뺍니다. (기존 `s3-logs/s3-access/` prefix 는 폐지)

**② `aws-waf-logs-` 는 🔴 네이밍 규칙의 유일한 예외입니다**

```
우리 규칙 : jangin-<env>-<resource>
WAF 로그  : aws-waf-logs-logs-jangin-{env}     ← AWS 하드 제약
```

AWS 가 **WAF 로그 대상 S3 버킷 이름은 `aws-waf-logs` 로 시작해야 한다**고 강제합니다.

🔴 **이 예외를 모르는 사람이 "규칙에 안 맞네" 하고 이름을 고치면 WAF 로깅이 조용히 멈춥니다.**
이름을 바꾸기 전에 반드시 이 문단을 확인하세요.

⚠️ 파트장님 문서 표기에 **`jagin-{env}-s3-access`** (`n` 누락) 오타가 있어 확인 요청드린 상태입니다. 위 표는 `jangin-` 기준입니다.

**`s3-logs` prefix 분리 필수 — 🔄 4종 → 3종**

```
s3-logs/cloudtrail/   ← 장기보관 (멘토 요구)
        vpc-flow/     ← VPC Flow Logs (보안팀 NAT 조건 4)
        loki/         ← Loki 청크 (단기)

❌ s3-access/   → 🔄 09-16 폐지. 별도 버킷 jangin-{env}-s3-access 로 이동
❌ waf/         → 🔄 09-16 폐지. 별도 버킷 aws-waf-logs-logs-jangin-{env} 로 이동
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
- **staging 버킷에는 `https://stg.midam.store` 추가** ✅ 09-16 DNS 확정으로 이 값 고정
- ⚠️ **SSE-KMS는 버킷 기본 암호화로 강제.** 버킷 정책에 *"암호화 헤더 없으면 Deny"* 를 **넣지 않음** (넣으면 FE가 헤더를 보내야 함). TLS 강제 Deny는 유지

### 공통 버킷 정책 (보안팀 요구)

| 조치 | 구현 |
|---|---|
| TLS 강제 | `aws:SecureTransport = false` Deny |
| ACL 비활성화 | `Object Ownership = Bucket owner enforced` |
| 접근 로깅 | 🔄 **09-16: → `jangin-{env}-s3-access` 버킷** (구: `s3-logs/s3-access/` prefix) |
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

**🆕 ☸️ CN (박명수) 09-16 반영분 — 인프라 영향**

| PR | 내용 | 인프라 영향 |
|---|---|---|
| **#21** (머지됨) | CNPG `nodeSelector: workload-type=db` + `toleration: workload=db` 추가 | ✅ **막힌 항목 해소.** ⑦ 사양이 이 값으로 **고정**됨 |
| **#21** (머지됨) | `podAntiAffinityType: preferred` → **`required`** | 🔴 **DB 노드 `min_size=3` · `ON_DEMAND` 강제** (「노드 구성」 참조) |
| **#21** (머지됨) | `k8s-validate.yml` CI 신설 (`paths: k8s/**`·`platform/**`) | terraform PR 에는 안 걸림. **terraform CI 는 여전히 부재** |
| **#24** (열림) | AI 를 **`ai-sglang`(L40S) / `ai-ollama`(T4)** 로 분리 | 🔴 **IRSA 6번 SA 이름 재확인**(막힌 항목 14) · 앱→AI 대상이 2개로 |
| **#24** (열림) | DB 수신 기본 차단 + Backend·CNPG 허용, Backend→AI 8000 허용 | ✅ 보안팀 NAT 조건 #1 **부분 충족** |
| **#24** (열림) | Backend 기본 차단·DB/AI 발신 차단은 **배포 미연결** (ALB·외부 API·**STS**·S3 예외 미완) | 🔴 **STS 예외 없이 연결되면 IRSA 6종 전부 실패**(막힌 항목 15) |
| **#24** (열림) | AI 이미지가 **임시 값** — 실제 ECR 주소·Digest 필요 | 막힌 항목 4·6 과 연결 |

> 🔗 **NetworkPolicy 는 CN 과업입니다** (작업규칙 13). 인프라는 **SG·NACL·NAT 계층**만 담당하고,
> 겹치는 지점만 협업 포인트로 짚습니다. **단, 아래 두 가지는 인프라 작업입니다.**

#### 🆕🔴 인프라 작업 A — VPC CNI NetworkPolicy 활성화 (막힌 항목 16)

EKS 에서 NetworkPolicy 는 **VPC CNI addon 에서 켜야 실제로 동작**합니다.

```
enableNetworkPolicy = "true"    ← aws-vpc-cni addon configuration
```

🔴 **안 켜면 NetworkPolicy 리소스는 생성되지만 아무것도 막지 않습니다. 에러도 안 납니다.**
명수님이 *"YAML 렌더링만으로 통신 차단 여부를 확인할 수 없다"* 고 쓰신 게 이 얘기이며,
**명수님이 만든 정책 전부가 무효가 되는 단일 실패점**입니다.

- 작업 위치: **⑥ EKS addon** 또는 **⑧** (애드온 단계)
- 검증: `kubectl -n kube-system get ds aws-node -o yaml | grep -i networkpolicy`
- ⚠️ 정책 시행 주체가 노드의 에이전트라 **노드가 뜬 뒤에야** 동작합니다

#### 🆕🔴 인프라 작업 B — CN 에 넘겨야 할 값 5종 (막힌 항목 15)

명수님이 PR #24 에 **명시적으로 요청**한 항목입니다. 이게 없으면 DB·Backend·AI **발신 정책을 영영 연결 못 합니다.**

| # | 항목 | 인프라가 줘야 할 것 | 🔴 주의 |
|---|---|---|---|
| 1 | **CNPG → Kubernetes API** (443) | EKS API endpoint 의 **실제 목적지 IP/CIDR** | 🔴 **Q-PL-01 엔드포인트 공개 범위 결정에 종속.**<br>public 이면 EKS 공인 IP, private 이면 **VPC 내 ENI IP**(AWS 가 관리, 변할 수 있음) |
| 2 | **백업 워크로드 → STS** (443) | `sts.ap-northeast-2.amazonaws.com` 의 IP 범위 | 🔴 **NAT 경유**(Interface Endpoint 미도입 확정).<br>NAT EIP 는 **출발지**이지 목적지가 아님 — 명수님 지적 정확 |
| 3 | **백업 워크로드 → S3** (443) | 리전 S3 **CIDR 목록 + 갱신 방법** | 🔴 **prefix list ID 를 NetworkPolicy 에 넣을 수 없음.**<br>SG 는 되지만 NetworkPolicy 는 **CIDR 만** 받음 — 명수님 지적 정확 |
| 4 | **DNS 구성** | CoreDNS 라벨 / NodeLocal DNS 사용 여부 | 미사용 확정이면 그대로 답하면 됨 |
| 5 | **S3 Gateway Endpoint 경로** | Endpoint ID · 연결된 라우팅 테이블 | 🔴 **9/18 apply 후에야 실제 ID 가 나옵니다** |

> 🔴 **1·5 는 9/18 apply 전에는 값 자체가 없습니다.** CN 에 *"apply 후 제공"* 으로 일정을 맞춰야 합니다.

> 💡 **3번 S3 는 트레이드오프를 함께 제시해야 합니다.**
> S3 공인 IP 대역은 AWS 가 수시로 갱신합니다. NetworkPolicy 에 CIDR 로 박으면 **목록이 바뀔 때마다 사람이 갱신**해야 하고, 놓치면 **백업이 조용히 실패**합니다.
> 심층 방어 관점에서 S3 접근 제한은 **IAM + Endpoint Policy + Bucket Policy** 3계층이 이미 담당하므로,
> NetworkPolicy 는 **443 포트 단위 허용**에 그치는 선택지가 있습니다.
> ⚠️ 명수님은 *"외부 HTTPS 전체 허용으로 예외를 대신하지 않는다"* 는 원칙을 세우셨으므로 **보안팀·CN·인프라 합의 사안**입니다. 인프라 단독 결정 아님.

**🔐 보안** — 3-tier · SG Reference · IRSA · **CSI Driver 볼륨 마운트**
- **NAT Gateway 조건부 승인 5건** — 아래
- **AI Pod DAST 범위 편입** · **스테이징 GPU 필요** (스캔 시점만)
- 🔴 **CloudFront OAC 권고** · **EXIF 서버측 백스톱 권고** (MVP는 잔여위험)
- IAM: Root MFA · AccessKey 미생성 · **한시적 admin 9/15~17 회수**
- 스테이징 DAST 8항목
- 🆕 **09-16 문서 표현 수정 요구**: *"3-tier"* → **"전통적인 서브넷 기반 3-tier 가 아니라, EKS 내부 워크로드에 Kubernetes 네트워크 정책과 노드 격리를 적용한 **논리적 3-tier 구조**"** — 문서 5종 반영 대상

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
| **21** | 🆕🔴 **"설정"이 아니라 "실물"을 확인한다.** 버킷 설정이 SSE-KMS 라도 객체는 AES256 일 수 있다.<br>보안 항목 검증은 리소스 설정 조회가 아니라 **결과물 조회**로 한다 — 예: `aws s3api head-object ... --query ServerSideEncryption`<br>*(09-16 실제 사례: `backend.tf` 의 `encrypt = true` 가 버킷 기본 암호화를 덮어써서, 콘솔엔 KMS 인데 State 는 SSE-S3 였음)* |
| **22** | 🆕 **셸 스크립트는 "생성 구간"과 "검증 구간"의 엄격도를 나눈다.** 생성은 `set -e` 로 즉시 중단, 검증은 `set +e` 로 끝까지 출력.<br>*(09-16 실제 사례: 키 교체 상태 조회 실패로 스크립트가 죽어, 가장 중요한 객체 암호화 확인이 실행되지 못함)* |
| **23** | 🆕🔴 **`terraform.tfvars` 의 기본값을 바꾸면 PR 만으로 끝내지 않는다.** `.gitignore` 대상이라 **PR 로 전파되지 않고**, 팀원 로컬 파일은 옛 값 그대로 남는다.<br>→ **①`terraform.tfvars.example` 갱신 + ②디스코드로 `grep` 확인 요청**까지가 한 세트.<br>*(09-17 실제 사례: `.example` 은 9/17 판인데 `terraform.tfvars` 는 9/15 판이라 `1.33`·`API_AND_CONFIG_MAP` 이 남아 있었음. 그대로 apply 했으면 **되돌릴 수 없는 클러스터 버전**이 구버전으로 생성)* |
| **24** | 🆕 **스택 PR(PR 위에 PR)은 본문에 base 와 머지 순서를 명시한다.** 아래부터 순서대로 머지해야 diff 가 섞이지 않는다.<br>같은 파일 끝을 여러 PR 이 건드리면 **나중에 머지되는 쪽이 rebase + `--force-with-lease`** 를 해야 하므로, 부재 예정이면 PR 본문에 그 사실을 적는다 |

> 📌 **규칙 10 보충 (2026-09-13)**: `NodePool` 값은 `system｜app｜db｜ai` 중 하나여야 Cost Explorer 필터가 의미를 갖습니다.
> VPC·서브넷·IGW·라우팅·SG·Endpoint 는 **요금이 $0** 이고 저 넷 중 어디에도 속하지 않으므로 **부여하지 않습니다.**
> 억지로 `network` 같은 값을 넣으면 비용 분석 필터만 오염됩니다. **⑦ 노드그룹 단계에서 리소스별로 부여합니다.**
> (파트장·다정님 확인 요청 중)

---

## 💰 비용 🔄 **재산정 v2.0 (2026-09-17 창원님)**

```
구 v1.0 :  $345.93 / $350        →  98.8%  🔴
신 v2.0 :  401,756원 / 500,000원  →  80.4%  ✅
```

| 구분 | 금액 | 비중 |
|---|---|---|
| **GPU 2대** (전부 온디맨드) | **$190.78** | **63.7%** |
| EC2 노드 (System·App·DB) | $21.97 | |
| EKS 컨트롤플레인 (264h) | $26.40 | |
| NAT Gateway | $18.53 | |
| ALB + WAF | $11.18 | |
| Vercel Pro | $20.00 | |
| 그 외 (S3·ECR·공인 IPv4·EBS 예비) | $10.52 | |
| **총액** | **$299.37 = 401,756원** | |

**산정 기준** — 🔄 일정이 바뀌어 구간이 짧아졌습니다
- 기간 **9/21 ~ 10/1** · 실운영 **7일** (9/21~23, 9/28~30, 10/1)
- 하루 **9h + 준비 15분 = 65h** · 상시 유지 **264h** · 크레딧 **$0**

- 🔴 **크레딧 $0** — IAM Identity Center **조직 인스턴스** 활성화로 소멸
- 🔴 **프리티어 없음** — EC2 DB라 RDS 무료 대상 아님. t3 전 계열 무료 시간 없음
- 🟡 **막힌 항목 21**: 500,000원이 **클라우드/보안 그룹 한도인지 8개 직군 전체 한도인지** 미확인.
  FE Vercel $20 · 보안팀 LLM 10,000원이 같은 한도에서 나가면 여유가 줄어듭니다

### 🟡 남은 절감 여지 2건 (둘 다 파트장·그룹장 판단)

| # | 항목 | 절감 추정 | 상태 |
|---|---|---|---|
| 1 | **g6e → g6** (L40S 48GB → L4 24GB) | 약 **$96 ≈ 13만원** | 🔴 **AI팀 VRAM 실측 대기.** 챗봇(gemma 4bit ≈ 7.2GB)은 24GB 에 들어갈 여지가 있으나 **이미지 모델 용량 미회신** |
| 2 | **GPU Spot 적용** | 약 **$90 ≈ 12만원** | 🟡 현재 시트는 **Spot 0일**(전부 온디맨드) |

```
g6e.xlarge   OD $2.288/h  vs  Spot $1.2306/h   → 65h 기준 약 $69 차이
g4dn.xlarge  OD $0.647/h  vs  Spot $0.3166/h   → 65h 기준 약 $21 차이
```

> 🟡 **Spot 의 트레이드오프**: AWS 가 용량이 필요하면 **2분 통보 후 회수**합니다.
> GPU 는 평소 0대로 두고 **테스트·시연 시간에만** 켜는데, **하필 그때 회수되면 시연이 멈춥니다.**
> → 인프라 의견: **최소한 10/6 시연일은 온디맨드**. 예산이 80.4% 로 내려온 만큼 무리해서 아낄 필요가 줄었습니다.

### 🔴 비용표에 안 잡힌 것 1건 — 종료 후 조용히 새는 요금

```
gp3 PV 20Gi × 3 (CNPG)  +  reclaimPolicy: Retain
  → terraform destroy 후에도 EBS 가 남아 계속 과금
  → 10/2 제출 ~ 10/6 발표 사이 요금 발생
```

> `Retain` 은 **"PVC 를 지워도 디스크는 남긴다"** 는 설정이라, DB 데이터 보호 목적으로는 옳습니다.
> 다만 **Terraform 이 만든 게 아니라 CSI 드라이버가 만든 볼륨**이라 `terraform destroy` 가 건드리지 않습니다.
> 🔴 **10/2 종료 체크리스트에 "고아 EBS 수동 삭제" 단계 필수** (인프라 담당).

### 🔴 끌 수 있는 것과 없는 것

| 구분 | 항목 | 시간 |
|---|---|---|
| **상시 264h** | **EKS 컨트롤플레인(끌 수 없음)** · NAT GW · ALB 기본료 · 공인 IPv4 | 11일×24h |
| 운영시간 65h | App · DB · GPU · ALB LCU | 7일×9.25h |

⚠️ **ALB를 못 끄는 이유**: Ingress를 지웠다 만들면 **ALB DNS가 바뀌어** Route53을 매일 갱신해야 함

---

## 📅 일정

| 시점 | 내용 |
|---|---|
| ✅ **9/12 (토)** | **IaC 착수** — Claude Code 세팅 · **① State 부트스트랩** (PR #3) |
| ✅ **9/13 (일)** | **② VPC (PR #4) · ③ SG (PR #5) · ④ S3 Endpoint (PR #6)** — 관리 리소스 41개 · $0 |
| ✅ **9/14 (월)** | 보안팀 검토 요청 · 타 직군 질문 · **파트장 설계서 최종본 수령** · 로컬 동기화 |
| ✅ **9/15 (화)** | 🔄 **모듈화 B안 최종 확정**(오전 A안 → 저녁 정정) · **CloudFront OAC 확정** · 🔴 **네트워크 리소스 destroy** · PR #12·#15·#16 머지 |
| ✅ **9/16 (수)** | **PR #13·#18·#21 머지** · 🔄 **`modules/nat` 분리**(파트장 리뷰) · ✅ **State SSE-KMS 전환** · 파트장 **엣지·S3 설계서** 수령 · 명수님 **PR #24 NetworkPolicy**<br>🔴 **재apply 안 함 — 파트장 지시로 9/18 일괄로 통합** |
| ✅ **9/17 (목)** | 🔴 **신준한 결석** (개인 작업으로 수행) · **EKS 3대 결정 확정** · **Karpenter/KEDA 미사용 확정** · **노드 사양 변경** · **비용 재산정 v2.0**<br>코드: **PR #35·#36·#37** (⑥ 결정 반영 / ⑦ 노드그룹 / ⑧ 애드온) — `Plan: 66 to add, 0 to change, 0 to destroy` · 🔴 **apply 안 함**(규칙 17) |
| 🔴 **9/18 (금)** | 🔴 **⑤~⑧ 일괄 `apply`** · **프로비저닝 완료** · **17시 발표**(네이티브 합동 여부 리드 회의 확인 필요)<br>🔴 **신준한 연속 부재** — 아래 「9/18 인수인계」 |
| 9/15~17 | IAM 한시적 admin 회수 (박다정) |
| **9/21** | **실제 연동 테스트 시작** · 스테이징 제공(DAST) |
| 9/22 (화) | 인프라 멘토링 3차 |
| **~9/30** | **평일 6일간 검토** (파트장 9/15 확정) |
| 9/24~27 | **추석 연휴 + 주말** — 운영 중단 |
| **10/1~10/4** | 🔄 **노드 내리기** (비용 절감) |
| **10/2 17:00** | 결과물 제출 |
| **10/5~10/6** | 🔄 **노드 올리고 확인 + 발표 시연 준비** |
| **10/6** | 최종 발표 (30분 + Q&A 20분) |

**운영 스케줄**: 09:00~18:00 (하루 9시간) · 🔄 **09-17 재산정 기준 실운영 7일** (9/21~23 · 9/28~30 · 10/1)

### 🔴 9/18 인수인계 (신준한 부재)

| # | 항목 | 확인 방법 |
|---|---|---|
| 1 | **팀원 공인 IP 를 `terraform.tfvars` 에 채우기** | 각자 `curl ifconfig.me` → `eks_public_access_cidrs = ["x.x.x.x/32", ...]`<br>🔴 비어 있으면 **PR #35 의 precondition 으로 `plan` 실패** |
| 2 | 🔴 **각자 `terraform.tfvars` 최신인지 확인** | `grep -E 'eks_cluster_version\|eks_authentication_mode' terraform.tfvars`<br>`1.33`·`API_AND_CONFIG_MAP` 이 보이면 **옛 파일**. 클러스터 버전은 **되돌릴 수 없음** (규칙 23) |
| 3 | **PR 머지 순서** | `#35 → #36 → #37` (스택). #32 와 `outputs.tf` 충돌 — **양쪽 다 append 라 둘 다 남기면 끝** |
| 4 | 🔴 **막힌 항목 18(앱 KMS CMK)** | 해결 전 apply 하면 IAM 정책 생성에서 실패. **`plan` 으로는 안 잡힘** |
| 5 | 🔴 **막힌 항목 19(⑩ 엣지 모듈 미호출)** | apply 해도 ALB·CloudFront 가 안 생김. **`plan` 으로는 안 잡힘** |
| 6 | **apply 직후 State 암호화 실물 확인** | `aws s3api head-object --bucket jangin-infra-s3-tfstate --key prod/terraform.tfstate --query ServerSideEncryption` → `"aws:kms"` (규칙 21) |
| 7 | **새 리소스 ID 수집** | 「배포 리소스 현황」 표 채우기 — 인계 문서 재료 |

> 💰 **비용 재산정 대상**: 기존 v1.0 산정은 **운영일 11일 + 달력 17일** 기준이었습니다.
> 새 일정은 **9/18 시작 · 가동 9일**이라 상시 요금(EKS 컨트롤플레인·NAT·ALB·공인 IPv4) 구간도 **약 13일**로 줄어듭니다.
> → **9/18 apply 직후 재산정**하면 예산 98.8% 압박이 완화될 수 있습니다.

### IaC 착수 순서

```
✅ ① Terraform State (S3 + DynamoDB Lock)   ← CLI 수동 생성      PR #3
✅ ② VPC · 서브넷 6개 · 라우팅 · IGW          ← 무료             PR #4
✅ ③ Security Group 4종 (sg-eks-gpu 포함)     ← 무료             PR #5
✅ ④ S3 Gateway Endpoint                      ← 무료             PR #6
✅ ②③④ 모듈 구조로 재작성 (코드만)            ← 무료             PR #18 머지 ✅
   ⑤ NAT Gateway + EIP(prevent_destroy)       ← 💰 9/18          PR #19 (리뷰 반영 완료)
   ⑥ EKS 클러스터 + OIDC Provider              ← 💰 9/18          PR #22
✅ ⑦ 노드그룹 6종 (system-md/system-lg/app/db/gpu-a/gpu-b)  ← 💰 9/18   PR #36
🔄 ⑧ KMS CMK + Parameter Store + IRSA 6종 + EBS CSI Driver 애드온   ← 분담 필요
   ⑨ S3 버킷 🔄 7종 (prefix·lifecycle·CORS·접근로그·WAF로그)
   ⑩ ALB · WAF · Route53 · ACM · CloudFront   🔗 파트장 영역
```

> 🔴 **①~④ 는 9/13 에 배포했으나 9/15 destroy 되었습니다.** ① State 백엔드(S3·DynamoDB)는 그대로 살아 있고, ②③④ AWS 리소스만 삭제됐습니다.
> 🔄 **09-16 정정: ②③④ 를 따로 재apply 하지 않습니다.** 파트장님이 *"apply 는 일괄 진행"* 으로 정하셔서 **9/18 에 ②~⑧ 을 한 번에** 올립니다.
> (이전 판의 *"9/16 중 재apply"* 는 폐기됐습니다)
> 💰 **⑤ 이후는 과금.** 9/17 까지 `plan` 까지만, **9/18 일괄 `apply`** (규칙 17)
>
> 🆕🔴 **⑧ 은 3명이 나눠 갖고 있습니다 — 빈칸이 있습니다**
>
> | ⑧ 구성요소 | 담당 | 상태 |
> |---|---|---|
> | IRSA 6종 | 박다정 | 🟡 **PR #32 리뷰 대기** |
> | **앱용 KMS CMK** | 🔴 **미정** | 🔴 **아무도 안 만들고 있음** (막힌 항목 18) |
> | Parameter Store | 🔴 **미정** | ⬜ |
> | EKS 애드온(VPC CNI·CoreDNS·kube-proxy) | 신준한 | ✅ **PR #37** |
> | EBS CSI Driver | 신준한 | 🟡 **#32 머지 후 3줄** — `ebs_csi_enabled = true` + `module.irsa["ebs-csi"].role_arn` |
>
> ⚠️ **State 용 CMK(`alias/jangin-infra-s3-tfstate`)는 위 "앱용 CMK" 와 별개 키**입니다. 혼동하면 순환 의존이 다시 생깁니다.
>
> 🆕🔴 **⑦ 에 `AmazonSSMManagedInstanceCore` 를 빠뜨리지 마세요** (다정님 BE 접근 안내).
> 노드 IAM 역할에 이 정책이 없으면 **SSM Session Manager 로 노드에 못 들어갑니다.**
> Bastion 을 만들지 않기로 한 설계라, 이게 유일한 접근 경로입니다.
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
| 1 | IaC 모듈 코드 + 환경 배포 + **IaC CI plan·정책 검증** | 🔄 **09-16: CN 은 `k8s-validate.yml` CI 를 이미 만듦**(PR #21). terraform CI 는 여전히 없음 → `fmt -check` + `validate` 워크플로 제안 예정 |
| 2 | **클러스터 환경 인계 문서** (CN 협업) | ⬜ |
| 3 | 구성 관리 자동화 스크립트 + 이미지 빌드 자동화 | ⬜ |
| 4 | 백업·복원 검증 + **멀티 AZ HA 적용 결과** | 🔴 단일 AZ와 충돌 |
| 5 | **AutoScaling 정책 구성·시연** | 🔄 **09-17: Karpenter·KEDA 미사용 확정 → HPA 만 남음.**<br>노드 오토스케일링 시연은 불가. **Pod 단위 HPA + 노드그룹 `max_size` 여유**(system 2 / app 3)로 재구성 필요 🔗 CN |

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
    │   ├── network/  ✅ 완료      VPC·Subnet·IGW·RouteTable        [인프라 ②]  무료
    │   ├── nat/      🆕 09-16      NAT GW·EIP·Route·알람            [인프라 ⑤]  💰 유료
    │   ├── security/ ✅ 완료      SG 4종 + Rule 15개                [인프라 ③]  무료
    │   ├── endpoints/ ✅ 완료     S3 Gateway Endpoint               [인프라 ④]  무료
    │   ├── eks/      🔄 PR #22    Cluster·OIDC                      [인프라 ⑥]  💰 유료
    │   │                 🔄 PR #35 로 1.35·API·엔드포인트 precondition 추가
    │   ├── eks_nodes/  🆕 PR #36   노드그룹 6종 + 노드 IAM Role      [인프라 ⑦]  💰 유료
    │   ├── eks_addons/ 🆕 PR #37   VPC CNI·CoreDNS·kube-proxy·EBS CSI [인프라 ⑧]  무료
    │   ├── irsa/     🟡 PR #32    IRSA 6종                        🔗 [박다정 ⑧]
    │   ├── ecr/      ✅ 완료      ECR 레포·수명주기               🔗 [이창원 PR #12]
    │   ├── acm_alb/  ✅ 완료      ALB용 ACM + Route53 검증        🔗 [강윤주 PR #15]
    │   ├── acm_cloudfront/ ✅     CloudFront용 ACM (us-east-1)    🔗 [강윤주 PR #15]
    │   ├── alb/      ✅ 완료      ALB                             🔗 [강윤주 PR #15]
    │   ├── cloudfront/ ✅ 완료    CloudFront + OAC                🔗 [강윤주 PR #15]
    │   └── waf/      ✅ 완료      WAF                             🔗 [강윤주 PR #15]
    │                 🔴 09-17: 엣지 5종은 모듈만 있고 environments 에서 호출되지 않음 (막힌 항목 19)
    └── environments/
        ├── prod/                       ← 🔴 module 호출만. 리소스 직접 선언 금지
        │   ├── versions.tf · backend.tf · providers.tf · locals.tf
        │   ├── vpc.tf                  ← module "network" 호출     ┐
        │   ├── nat.tf         🆕 09-16 ← module "nat" 호출          │
        │   ├── eks.tf                  ← module "eks" 호출          │
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
| **16** | 🆕🔴 **IAM 정책 `statement` 마다 `resources` 가 있는가** — 신원 기반 정책의 `Allow` 문은 `Resource` 가 필수.<br>⚠️ **`plan` 에서는 안 잡힙니다.** 정책 JSON 은 Terraform 이 로컬에서 조립하는 데이터라 plan 을 통과하고, AWS 검증은 **apply 순간에만** 일어나 `MalformedPolicyDocument` 로 실패합니다.<br>*(09-17 발견: PR #32 의 `kms:Decrypt` statement 2건)* |
| **17** | 🆕 **`min_size`·`capacity_type` 같은 "제약"은 주석이 아니라 `precondition` 으로 박았는가** (규칙 12 의 오버엔지니어링과 혼동 주의 — **틀리면 조용히 망가지는 값**에만 적용) |

💡 **plan 출력**: `Plan: N to add, 0 to change, 0 to destroy`
**`to destroy`가 0이 아니면 절대 apply하지 마세요.**
💡 **모듈 이관 PR 의 기대 출력**: `Plan: 0 to add, 0 to change, 0 to destroy.` + 이동 목록만

---

## 평가 기준 (클라우드·보안 그룹)

**전문성 30**(환경설계·비용통제) / **차별성 30**(운영·보안 리스크 인식) / **완성도 30**(**실제 동작 여부** + 타 직군 인계 문서) / **발표 10**(**비전문가도 이해 가능하게**)

→ 제안할 때 **어느 항목 점수를 노리는지 밝힐 것.**

---

## 🔴 배포 리소스 현황 (2026-09-17 기준 — 변동 없음)

> 계정은 이 문서에 적지 않습니다 (작업 규칙 2). SSO 프로필 `jangin` · Permission Set `Infra-Admin` · 리전 `ap-northeast-2`

| 구분 | 상태 |
|---|---|
| ① **State 백엔드** | ✅ **살아 있음** — `jangin-infra-s3-tfstate` / `jangin-infra-ddb-tfstate-lock` |
| ① **State 암호화** | 🔄 **09-16 SSE-KMS(CMK) 전환 완료** — 아래 상세 |
| ②③④ **VPC · SG · Endpoint** | 🔴 **없음** — 9/15 destroy. 코드는 PR #18 로 `main` 에 머지됨. **apply 는 9/18** |
| ⑤~⑧ | ⬜ 미생성 — **코드는 PR #19·#22·#35·#36·#37 로 준비 완료.** `Plan: 66 to add` |
| ⑨⑩ | ⬜ 미생성 — 🔴 **⑩ 은 모듈만 있고 환경에서 호출되지 않음** (막힌 항목 19) |

### 🆕 ① State 백엔드 상세 (09-16 갱신)

| 항목 | 값 | 비고 |
|---|---|---|
| 버킷 | `jangin-infra-s3-tfstate` | |
| Lock | `jangin-infra-ddb-tfstate-lock` | |
| 버전 관리 | `Enabled` | State 손상 시 **유일한** 복구 수단 |
| 기본 암호화 | 🔄 **`aws:kms` (CMK)** | 구: `AES256` |
| **KMS 키** | **`alias/jangin-infra-s3-tfstate`** | 🔴 **Terraform 이 관리하지 않음** |
| 키 교체 | `True` (연 1회) | |
| Bucket Key | `True` | 💰 KMS 요청 비용 절감 |
| TLS 강제 | `DenyInsecureTransport` | |
| Public Access Block | 4종 전부 `True` | |

🔴 **State 용 CMK 를 Terraform 으로 만들지 않는 이유 — 순환 의존**

```
⑧ 에서 Terraform 이 만든 CMK 로 State 버킷을 암호화하면
  → "State 를 담은 금고의 열쇠를 그 State 가 관리"
  → terraform destroy (⑧) → 키 삭제 대기(7~30일)
  → State 복호화 불가 → plan 도 destroy 도 못 함 → 🔴 복구 불가
```

그래서 **State 용 CMK 는 `scripts/bootstrap-tfstate.sh` 가 CLI 로 만들고, ⑧ 의 애플리케이션용 CMK 와 별개 키**로 유지합니다.

🔴 **`backend.tf` 에 `kms_key_id` 가 반드시 있어야 합니다**

`encrypt = true` 만 있고 `kms_key_id` 가 없으면 Terraform 이 PutObject 에 **AES256 헤더를 직접 붙여** 버킷 기본 암호화를 덮어씁니다.
→ **콘솔엔 KMS 인데 State 실물은 SSE-S3** 가 됩니다. (09-16 실측으로 확인)

```bash
# 검증은 버킷 설정이 아니라 객체로 (작업 규칙 21)
aws s3api head-object --bucket jangin-infra-s3-tfstate \
  --key prod/terraform.tfstate --query ServerSideEncryption
# → "aws:kms" 여야 정상
```

⚠️ **현재는 아직 `AES256` 입니다.** 기존 객체는 재암호화되지 않고, **9/18 첫 apply 에서 State 가 새로 쓰일 때** `aws:kms` 로 바뀝니다.
→ 🔴 **9/18 apply 직후 위 명령 재확인이 완료 조건입니다.**
→ 구버전 State 는 `AES256` 으로 남습니다. 지우면 복구 수단이 사라지므로 **잔여 위험으로 기록**하고 종료 시 정리합니다.

🔴 **타 직군 영향**: 창원님 CI(GitHub Actions) 역할에 **`kms:Decrypt`(plan) · `kms:GenerateDataKey`(apply)** 가 필요합니다.
키 정책은 계정 루트 위임이라 **IAM 정책 추가만으로 됩니다** (다정님 영역).
💰 CMK 1개 = 월 약 **$1** — 비용 보고서 v1.0 미반영 항목.

### 🔴🆕 09-16 발견 — 무효 ID 가 타 직군 문서에 살아 있습니다 (막힌 항목 17)

명수님 PR #24 의 `k8s/README.md` 에 아래 값이 인용돼 있습니다. **팀 컨텍스트 v0.8 · DB 값·CI 설정 문서에서 가져오신 것**입니다.

| 값 | 판정 | 이유 |
|---|---|---|
| `vpce-02f0b4007562d1132` (S3 Gateway Endpoint) | 🔴 **무효** | 9/15 destroy 됨. **9/18 apply 후 새 ID 가 생깁니다** |
| `pl-78a54011` (S3 Prefix List) | ✅ **유효** | **AWS 관리형**이라 우리가 만든 게 아님. 계정·리전 고정값이라 destroy 와 무관 |

> 🔑 **둘을 구분하는 게 핵심입니다.** *"9/15 에 다 지웠으니 둘 다 무효"* 로 뭉뚱그리면,
> 실제로는 살아 있는 prefix list 를 다시 찾느라 시간을 씁니다.
> **우리가 만든 것(`vpce-`)** 과 **AWS 가 주는 것(`pl-`)** 은 생명주기가 다릅니다.

명수님은 *"이 기록을 실제 AWS 상태로 간주하지 않는다"* 고 신중하게 쓰셨지만,
**다른 팀원은 그대로 쓸 수 있습니다.** → 🔴 **팀 컨텍스트 v0.8 과 DB 값 문서에서 `vpce-` 를 걷어내는 정정 공지가 필요합니다.**

> 🔴 **이전 판(09-14)에 있던 리소스 ID 표는 전부 무효**라 삭제했습니다.
> `vpc-014f8fb…` 등 예전 ID 를 타 직군 문서·설정에 쓰면 안 됩니다.
> **9/18 apply 후 새 ID 로 이 표를 채웁니다.** (인계 문서 재료 — 완성도 30점)

**9/18 apply 후 채울 항목**: VPC · subnet ×6 · route table ×3 · IGW · SG ×4 + default SG · S3 Gateway Endpoint · prefix list · **NAT EIP 공인 IP(🔑 스마트택배 allowlist)** · EKS 엔드포인트 · OIDC Provider ARN

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

**09-17 (EKS 3대 결정 확정 · 노드 사양 변경 · 비용 재산정 v2.0 · ⑦⑧ 코드)**
- 🔴 **신준한 결석** — 회의록·디스코드·비용표로 복기 후 개인 작업으로 수행
- ✅ **EKS 3대 결정 확정** — `1.35` / `API` / **(B) public(팀원 IP 제한)+private → 9/21 부터 private only**
  - 🔴 **자기 정정**: 제가 9/16 에 *"3대 결정 전부 비가역"* 이라고 안내한 것이 **틀렸습니다.**
    진짜 비가역은 **클러스터 버전 하나**이고, 인증 모드는 한 방향, **엔드포인트는 몇 분이면 전환**됩니다.
    셋을 묶어 무겁게 만든 탓에 실제보다 보수적인 선택으로 기울었습니다
  - 🔑 **재검토 근거가 된 새 사실**: `private only` 면 **Helm 최초 설치**(ArgoCD·CNPG·Argo Rollouts·Secrets Store CSI)가 막힙니다.
    SSM 우회는 **노드 IAM 역할에 클러스터 관리자 권한**을 요구해 **그 노드의 모든 Pod 가 클러스터 관리자**가 됩니다 — 보안을 위한 선택이 더 큰 구멍을 만듭니다.
    또 **10/1~10/4 노드를 내리면 SSM 으로 들어갈 노드가 0대**라 접근 자체가 불가능해집니다
  - 🔴 **전환 시점·근거·전후 설정을 기록해야** 의미가 있습니다. 그냥 바꾸면 *"중간에 흔들렸다"* 로 읽힙니다 (차별성 30)
- 🔄 **노드 사양 변경** — System `t3.medium`×1 + **`t3.large`**×1 / App `t3.medium`**×2** (Redis 배치 사유)
  - 부수 효과로 **막힌 항목 10(App OOM 위험) 해소**
- ✅ **Karpenter · KEDA 미사용 확정** — 🔴 Phase3 산출물 5번(AutoScaling 시연)이 **HPA 만** 남음
- ✅ **비용 재산정 v2.0** (창원님) — **401,756원 / 500,000원 = 80.4%** (구 98.8%)
  - 🔴 **비용표 미반영 1건**: `reclaimPolicy: Retain` 인 gp3 PV 3개가 destroy 후에도 남아 과금 → **10/2 종료 체크리스트에 수동 삭제 단계 필수**
- 🆕 **코드 3개 PR** — `Plan: 66 to add, 0 to change, 0 to destroy` · 🔴 **apply 안 함**(규칙 17)
  - **#35** EKS 결정 반영 + **엔드포인트 안전장치 precondition**(public 인데 IP 목록이 비었거나 `0.0.0.0/0` 이면 plan 실패)
  - **#36** `modules/eks_nodes` — 노드그룹 6종 · 노드 IAM 4정책(🔑 `AmazonSSMManagedInstanceCore` 포함) · **DB 제약 3건을 precondition 으로 강제**
  - **#37** `modules/eks_addons` — 🔴 **VPC CNI `enableNetworkPolicy = "true"`**(막힌 항목 16 해소) · `OVERWRITE` 로 self-managed 애드온 승격 · EBS CSI 는 IRSA 대기로 기본 `false`
- 🔄 **GPU 스토리지 방침 정정** — 로컬 NVMe → **루트 EBS 상향**(g6e 200GB / g4dn 120GB)
  - 사유: AL2023 `nodeadm` userData 는 **클러스터 없이 테스트 불가** + 실패 증상이 불명확 + 🔴 **9/18 부재**. 비용 차 약 $6
  - 🔄 **되돌릴 수 있는 결정** — 구축 안정 후 별도 PR 로 재검토
- 🆕 **막힌 항목 18~22 신설** — 앱 KMS CMK 담당 미정 · **⑩ 엣지 모듈 미호출** · 팀원 IP 미수집 · 예산 한도 범위 · 산출물3 초본 불일치 10건
  - 🔴 **18·19 는 둘 다 `plan` 으로 못 잡습니다.** 18 은 AWS 검증이 apply 시점이라서, 19 는 *"없는 코드는 차이가 아니라서"*
- 🆕 **작업규칙 23·24 신설** — `terraform.tfvars` 는 PR 로 전파되지 않음 · 스택 PR 머지 순서 명시 (둘 다 09-17 실제 사고)
- 🆕 **검수 체크리스트 16·17 신설** — IAM statement `resources` 확인 · 제약은 주석이 아니라 `precondition`

**09-16 (State KMS 전환 · S3 7종 · DNS 확정 · CN PR #21·#24 반영)**
- ✅ **PR #13·#18·#21 머지** — CLAUDE.md 9/15판 / 네트워크 모듈화 B안 / CN 워크로드 배치
- 🔄 **`modules/nat` 분리** (파트장 PR #19 리뷰) — "1 모듈 = 1 관심사" + **모듈 경계 = 과금 경계**
  - `depends_on(IGW)` → `internet_gateway_id` output + **precondition** 으로 대체 (모듈 단위 `depends_on` 의 부작용 회피)
  - 검증: `Plan: 46 to add, 0 to change, 0 to destroy` — 리팩터링 전과 동일
- ✅ **State 암호화 SSE-KMS(CMK) 전환** (파트장 지적) — `alias/jangin-infra-s3-tfstate`
  - 🔴 **추가 발견**: `backend.tf` 의 `encrypt = true` 가 버킷 기본 암호화를 덮어씀. `kms_key_id` 동반 필수
  - 실측 확인: 헤더 없이 업로드 → `aws:kms` / `--sse AES256` 업로드 → `AES256`
  - 🔴 State CMK 는 **Terraform 이 관리하지 않음** (⑧ CMK 로 쓰면 순환 의존 → destroy 시 복구 불가)
- 🔄 **S3 버킷 5종 → 7종** (파트장 「엣지·S3 버킷 설계서」)
  - 🆕 `jangin-{env}-s3-access` (**SSE-S3 필수** — KMS 면 접근 로그가 에러 없이 안 쌓임)
  - 🆕 `aws-waf-logs-logs-jangin-{env}` (**네이밍 규칙의 유일한 예외** — AWS 하드 제약)
  - `s3-logs` prefix 4종 → **3종** (`s3-access/`·`waf/` 폐지)
- ✅ **DNS 전부 확정** — `stg.` 채택. 🆕 `api.stg.midam.store` · 🆕 `img.midam.store`
  - ⚠️ **DNS 는 `stg.` / 리소스 접두사는 `staging`** — 별개 축 유지
- 🔴 **DB 노드그룹 제약 확정** (명수님 PR #21 `podAntiAffinityType: required`)
  - `min_size=3` · `ON_DEMAND` · Label `workload-type=db` + Taint `workload=db` (**키가 서로 다름**)
- 🆕 **막힌 항목 15·16·17 신설** (14 는 확인 후 즉시 해소)
  - 14 ✅ — 두 AI Deployment 가 `ai-worker-sa` 를 **공유**. IRSA 6번 그대로 유효
  - 15 🔴 — **인프라가 CN 에 넘겨야 할 값 5종** (EKS API·STS·S3 CIDR·DNS·Gateway Endpoint)
  - 16 🔴 — **VPC CNI `enableNetworkPolicy` 미활성화** → 정책이 에러 없이 무시됨
  - 17 🔴 — **무효 `vpce-` ID 가 타 직군 문서에 살아 있음** (`pl-` 은 AWS 관리형이라 유효)
- 🆕 **작업규칙 21·22 신설** — "설정이 아니라 실물 확인" · "생성/검증 구간 엄격도 분리" (둘 다 09-16 실제 사고)
- 🔄 **일정 정정** — *"9/16 중 ②③④ 재apply"* 폐기. 파트장 지시로 **9/18 일괄 apply** 로 통합
- 🆕 **⑦ 에 `AmazonSSMManagedInstanceCore` 명시** (다정님 요구 — 없으면 노드 접근 불가)

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