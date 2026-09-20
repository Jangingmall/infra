variable "project" {
  description = "프로젝트 식별자. 모든 리소스 이름의 맨 앞에 붙는다."
  type        = string
  default     = "jangin"
}

variable "env" {
  description = "환경 구분. 리소스 이름과 Environment 태그에 쓰인다."
  type        = string
  default     = "staging"

  validation {
    condition     = contains(["prod", "staging"], var.env)
    error_message = "env 는 prod 또는 staging 만 허용합니다."
  }
}

variable "region" {
  description = "AWS 리전. 작업 규칙 4에 따라 하드코딩하지 않는다."
  type        = string
  default     = "ap-northeast-2"
}

variable "vpc_cidr" {
  description = "staging VPC CIDR."
  type        = string
  default     = "10.1.0.0/16"
}

variable "vpc_az_suffixes" {
  description = <<-EOT
    사용할 가용영역(AZ) 접미사. region 과 합쳐 실제 AZ 이름을 만든다.
    예: region=ap-northeast-2 + "a" => ap-northeast-2a

    AZ 이름 자체를 하드코딩하지 않기 위한 구조다 (작업 규칙 4).
    2개인 이유: ALB가 최소 2개 AZ의 서브넷을 요구한다.
    (실제 리소스는 MVP 방침상 AZ-a 에만 배치)
  EOT
  type        = list(string)
  default     = ["a", "c"]
}

variable "vpc_subnet_cidrs" {
  description = <<-EOT
    tier별 · AZ별 서브넷 CIDR.

    🔴 app 계층만 /20 인 이유:
       EKS VPC CNI는 Pod 하나마다 VPC의 실제 IP를 하나씩 준다.
       /24(약 250개)로는 Pod가 늘어나면 IP가 고갈되고,
       CIDR은 서브넷을 만든 뒤에는 절대 바꿀 수 없다.
       → /24 로 "정리"하지 말 것. (검수 체크리스트 #1)
  EOT

  type = object({
    public = map(string)
    app    = map(string)
    data   = map(string)
  })

  default = {
    public = {
      a = "10.1.0.0/24"
      c = "10.1.1.0/24"
    }
    app = {
      a = "10.1.16.0/20"
      c = "10.1.32.0/20"
    }
    data = {
      a = "10.1.2.0/24"
      c = "10.1.3.0/24"
    }
  }
}

variable "eks_cluster_name" {
  description = "EKS 클러스터 이름. 서브넷 태그와 클러스터 생성에 공통 사용."
  type        = string
  default     = "jangin-staging-eks-cluster"
}

variable "nat_enabled" {
  description = <<-EOT
    NAT Gateway 생성 여부.
    false 로 두면 NAT 와 app 라우팅 경로만 사라지고 EIP(고정 공인 IP)는 남는다.
    → 10/1~10/4 환경을 내릴 때 값 하나로 비용을 끊되,
      스마트택배 allowlist 에 등록된 IP 는 유지된다. (작업 규칙 12)
  EOT
  type        = bool
  default     = true
}

variable "nat_gateway_az" {
  description = <<-EOT
    NAT Gateway 를 둘 AZ 접미사. vpc_az_suffixes 안의 값이어야 한다.
    🔴 MVP 는 AZ-a 단일 — 해당 AZ 장애 시 아웃바운드 전체가 끊긴다.
       (보안팀 NAT 승인 조건 #5 — 잔여 리스크로 문서화)
  EOT
  type        = string
  default     = "a"
}

# TODO(staging 값 확정): 파트장: staging NAT 알림 SNS ARN 확인; 빈 목록은 미연결
variable "nat_alarm_sns_topic_arns" {
  description = <<-EOT
    NAT CloudWatch 알람의 알림 수신 SNS 토픽 ARN 목록.
    🟡 Budget 알림 SNS 재사용 여부 미확정 → 기본 빈 목록.
       빈 목록이어도 지표 수집과 알람 상태 표시는 정상 동작한다.
  EOT
  type        = list(string)
  default     = []
}

# ✅ 2026-09-17 팀 확정: 1.35 (prod·staging 동일)
#    🔴 apply 전 STANDARD_SUPPORT 구간인지 + 애드온 호환만 확인하세요
variable "eks_cluster_version" {
  description = <<-EOT
    ✅ 2026-09-17 팀 확정 — 쿠버네티스 버전 1.35.
    🔴 되돌릴 수 없습니다. 올릴 수만 있고 내릴 수 없어, 잘못되면 클러스터 재생성입니다.

    🔴 apply 전 반드시 확인 (아직 미확인):
      aws eks describe-cluster-versions --region ap-northeast-2 --output table
      aws eks describe-addon-versions --region ap-northeast-2 --kubernetes-version 1.35 \
        --query 'addons[?addonName==`aws-ebs-csi-driver` || addonName==`vpc-cni`]'

    확인 기준 두 가지
      1. STANDARD_SUPPORT 인가 — 확장 지원 구간은 시간당 추가 요금
      2. 애드온이 1.35 를 지원하는가
         · aws-ebs-csi-driver 없으면 CNPG PVC 가 Pending → DB Pod 3개가 안 뜸
         · vpc-cni(NetworkPolicy) 없으면 CN NetworkPolicy 가 에러 없이 무시됨

    ⚠️ "최신 = 좋은 것" 이 아닙니다. EKS 는 새 버전이 나와도 애드온이 몇 주 늦게 따라옵니다.
  EOT
  type        = string
  default     = "1.35"
}

# ✅ 2026-09-16 파트장 확정: API (prod·staging 동일) — aws-auth ConfigMap 미사용
variable "eks_authentication_mode" {
  description = <<-EOT
    ✅ 2026-09-16 파트장 확정 — API (AWS API 로만 권한 관리).

    구 방식(CONFIG_MAP)은 클러스터 안의 aws-auth ConfigMap 을 손으로 고칩니다.
    🔴 오타 하나로 전원이 클러스터에서 잠기는 사고가 EKS 에서 가장 흔한 사고 유형입니다.
    API 방식은 aws_eks_access_entry 라는 AWS 리소스로 관리해 그 위험이 구조적으로 없습니다.

    🔑 9/21 private only 전환과 궁합이 좋습니다.
       CONFIG_MAP 이면 "권한을 주려면 접속해야 하는데 접속하려면 권한이 필요한" 순환이 생기는데,
       API 는 클러스터에 붙지 않고 Terraform 만으로 권한을 줄 수 있습니다.

    ⚠️ 좁히는 방향으로만 변경 가능합니다. API 에서 CONFIG_MAP 으로 되돌릴 수 없습니다.
    ⚠️ bootstrap_cluster_creator_admin_permissions = true 라, apply 를 실행한 사람이
       자동으로 관리자가 됩니다. 나머지 팀원은 access entry 로 추가해야 합니다.
  EOT
  type        = string
  default     = "API"
}

# TODO(staging 값 확정): 박다정: 생성자 관리자 권한과 apply 주체 확인
variable "eks_bootstrap_creator_admin" {
  description = <<-EOT
    🔴 클러스터 생성자에게 자동으로 관리자 권한 부여 여부.

    ⚠️ 9/15~17 한시적 admin 회수와 충돌 가능.
       회수 대상 권한으로 apply 하면 회수 후 아무도 클러스터에 못 들어갑니다.
       → 회수 후에도 남는 Infra-Admin Permission Set 으로 apply 해야 합니다. (박다정 확인)
  EOT
  type        = bool
  default     = true
}

# ✅ 2026-09-17 팀 확정: B안 — 구축기(9/18~20)는 public(팀원 IP 제한)+private,
#    9/21 검수 시작 시 private only 로 전환. 전환은 클러스터 재생성 없이 몇 분
variable "eks_endpoint_public_access" {
  description = <<-EOT
    ✅ 2026-09-17 파트장 확정 — 단계 운영(B안).

      9/18 ~ 9/20 구축  : true  + public_access_cidrs 를 팀원 IP 로 제한
      9/21 ~ 검수·운영  : false 로 전환 (private only)

    전환은 클러스터 재생성 없이 몇 분이면 됩니다. 버전·인증모드와 달리 가역입니다.

    왜 구축 기간에는 열어두나
      ArgoCD·CloudNativePG·Argo Rollouts·Secrets Store CSI 를 Helm 으로 설치해야 하는데,
      private only 면 SSM 을 거쳐야 합니다. 노드에 kubectl 을 두는 우회는
      🔴 노드 IAM 역할에 클러스터 관리자 권한이 필요해, 그 노드의 모든 Pod 가
      클러스터를 조작할 수 있게 됩니다 — 보안을 위한 선택이 더 큰 구멍을 만듭니다.

    ⚠️ "공개"라도 인증 명부에 없으면 401 입니다. Public = 무방비가 아닙니다.
       건물 주소가 지도에 나오는 것과 현관문이 열려 있는 것은 다릅니다.
  EOT
  type        = bool
  default     = true
}

variable "eks_endpoint_private_access" {
  description = "VPC 내부 접근 허용. 노드 ↔ 컨트롤플레인 통신 안정성을 위해 true 권장."
  type        = bool
  default     = true
}

# ✅ 2026-09-17 확정: 기본값 [] — 0.0.0.0/0 전체 허용은 폐기됐습니다
#    🔴 실제 팀원 IP 는 terraform.tfvars 에서 채웁니다 (작업 규칙 23)
#    🟡 staging 은 9/21~23 DAST 스캐너 IP 추가 필요 — 보안팀 회신 대기
variable "eks_public_access_cidrs" {
  description = <<-EOT
    🔴 TODO — 팀원 IP 목록. **apply 전에 반드시 채워야 합니다.**

    파트장 9/17: "B안으로 작성해뒀습니다. IP 는 작성 필요합니다"

    형식: ["1.2.3.4/32", "5.6.7.8/32", ...]   (각자 IP 확인: curl ifconfig.me)

    ⚠️ staging 에는 9/21~23 DAST 스캐너 IP 도 함께 들어갑니다 (보안팀 9/17 공유 예정).

    🔴 default 를 빈 목록으로 둔 것은 의도입니다.
       ["0.0.0.0/0"] 을 기본값으로 두면 값을 빠뜨렸을 때 **조용히 전 세계에 열립니다.**
       빈 목록이면 modules/eks 의 precondition 이 apply 를 막아 실수를 잡아냅니다.

    ⚠️ 9/21 private only 전환 시에는 endpoint_public_access = false 와 함께
       이 값을 빈 목록으로 되돌립니다.
  EOT
  type        = list(string)
  default     = []
}

variable "eks_additional_security_group_ids" {
  description = "컨트롤플레인 ENI 에 추가로 붙일 SG. 보통 비워 둡니다(EKS 자동 SG 사용)."
  type        = list(string)
  default     = []
}

variable "eks_enabled_log_types" {
  description = <<-EOT
    컨트롤플레인 로그 종류. 보안팀 상쇄 조치 #1(감사 로그 활성화)에 해당합니다.
      api           API 서버 요청
      audit         누가 무엇을 했는지 — 🔑 보안 검수의 핵심
      authenticator 인증 시도·실패
    💰 CloudWatch Logs 요금 발생 (비용 산정서 미반영 — 파트장 확인 필요)
  EOT
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

variable "eks_log_retention_days" {
  description = <<-EOT
    컨트롤플레인 로그 보관 기간(일).
    🔴 Terraform 이 로그 그룹을 먼저 만들지 않으면 EKS 가 "무제한"으로 만들어
       프로젝트 종료 후에도 요금이 계속 나갑니다. 30일이면 10/6 발표까지 충분합니다.
  EOT
  type        = number
  default     = 30
}

# TODO(staging 값 확정): 보안팀: staging Secret 암호화 CMK ARN 확인; null은 미주입
variable "eks_secrets_kms_key_arn" {
  description = <<-EOT
    쿠버네티스 Secret 봉투 암호화용 KMS CMK ARN.
    🟡 ⑧ KMS 단계에서 채웁니다. 🔴 클러스터 생성 후 해제 불가(추가만 가능).
  EOT
  type        = string
  default     = null
}

# TODO(staging 값 확정): Q-PL-02: 공용 ECR 소유 state 확정 전 false 유지
variable "ecr_enabled" {
  description = "공용 ECR의 단일 관리 환경 확정 후 그 환경에서만 true. 두 환경 동시 활성화 금지"
  type        = bool
  default     = false
  nullable    = false
}

variable "ecr_repositories" {
  description = <<-EOT
    생성할 ECR 레포 이름 목록.
    팀 확정(CLAUDE.md 09-10): 단일 레포 jangin-app + 동일 아티팩트 승격 · Immutable.
    이미지는 env 무관 공용(1벌) — 태그로 stg→prod 승격하므로 레포명에 env 미포함.
    ※ AI 전용 레포 추가는 AI 이미지 배포 방식 확정 후 목록에 반영.
    ※ 태그 규칙(sha- vs staging-/prod-)은 blocker #2로 미정 — 확정 후 CI에 반영.
  EOT
  type        = list(string)
  default     = ["jangin-app"]
  nullable    = false
  validation {
    condition = length(distinct(var.ecr_repositories)) == length(var.ecr_repositories) && alltrue([
      for name in var.ecr_repositories : try(length(name) >= 2 && length(name) <= 256 && can(regex("^[a-z0-9]+(([.]|_|__|-+)[a-z0-9]+)*(/[a-z0-9]+(([.]|_|__|-+)[a-z0-9]+)*)*$", name)), false)
    ])
    error_message = "중복 없는 ECR 이름을 입력하세요. 이름은 2~256자이며 AWS repositoryName 패턴을 따라야 합니다."
  }
}

variable "ecr_keep_last_images" {
  description = "레포별 보관할 이미지 최대 개수(초과분 오래된 것부터 삭제)"
  type        = number
  default     = 10
  nullable    = false
  validation {
    condition     = var.ecr_keep_last_images >= 1 && floor(var.ecr_keep_last_images) == var.ecr_keep_last_images
    error_message = "keep_last_images 값은 1 이상의 정수여야 합니다."
  }
}

variable "ecr_untagged_expire_days" {
  description = "untagged 이미지 만료일(일)"
  type        = number
  default     = 7
  nullable    = false
  validation {
    condition     = var.ecr_untagged_expire_days >= 1 && floor(var.ecr_untagged_expire_days) == var.ecr_untagged_expire_days
    error_message = "untagged_expire_days 값은 1 이상의 정수여야 합니다."
  }
}

variable "ecr_kms_key_arn" {
  description = "저장 암호화용 KMS CMK ARN. null이면 AES256(기본). CMK는 보안팀 제공"
  type        = string
  default     = null
}

variable "ecr_tags" {
  description = "추가 공통 태그"
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------
# ⑦ 노드그룹 (nodes_ 접두사)   💰 유료
# ------------------------------------------------------------

variable "nodes_groups" {
  description = <<-EOT
    노드그룹 정의. 키가 노드그룹 이름의 접미사가 된다.

    🔴 labels·taints 는 CN(박명수님) 매니페스트 실물에서 역산한 값입니다.
       한 글자라도 다르면 해당 Pod 가 영원히 Pending 입니다.

    ⚠️ DB 만 Label 키(workload-type)와 Taint 키(workload)가 다릅니다.
       오타가 아니라 k8s/base/database/cluster.yaml 실물이 그렇습니다.

    ⚠️ GPU 는 enabled = true · desired_size = 0 입니다.
       노드그룹은 만들어두고 EC2 만 0대인 상태 — 값 하나로 즉시 기동합니다.
       (enabled = false 는 노드그룹 자체를 안 만드는 것이라 다릅니다)
  EOT

  type = map(object({
    enabled       = bool
    instance_type = string
    ami_type      = string
    desired_size  = number
    min_size      = number
    max_size      = number
    capacity_type = string
    disk_size     = number
    labels        = map(string)
    taints = list(object({
      key    = string
      value  = string
      effect = string
    }))
  }))

  default = {
    # ── System : 모니터링·ArgoCD·컨트롤러 ──────────────────────
    # 🔄 09-17 변경: t3.medium × 2 → medium 1 + large 1
    #    Redis 배치 논의 중 명수님 요청. EKS 관리형 노드그룹은 한 그룹에
    #    인스턴스 타입 하나가 원칙이라, 타입이 다르면 그룹을 나눠야 합니다.
    #    라벨은 둘 다 workload-type=system 이라 nodeSelector 는 그대로 동작합니다.
    "system-md" = {
      enabled       = true
      instance_type = "t3.medium"
      ami_type      = "AL2023_x86_64_STANDARD"
      desired_size  = 1
      min_size      = 1
      max_size      = 2
      capacity_type = "ON_DEMAND"
      disk_size     = 30
      labels        = { "workload-type" = "system" }
      taints        = []
    }
    "system-lg" = {
      enabled       = true
      instance_type = "t3.large"
      ami_type      = "AL2023_x86_64_STANDARD"
      desired_size  = 1
      min_size      = 1
      max_size      = 2
      capacity_type = "ON_DEMAND"
      disk_size     = 30
      labels        = { "workload-type" = "system" }
      taints        = []
    }

    # ── App : Backend Pod ────────────────────────────────────
    # 🔄 09-17 변경: 1대 → 2대 (Redis 대응)
    # 🔑 BE 가 limits.memory 를 4Gi → 1.5Gi 로 낮추기로 해서
    #    t3.medium(가용 약 3.4Gi)에 Pod 2개가 들어갑니다.
    "app" = {
      enabled       = true
      instance_type = "t3.medium"
      ami_type      = "AL2023_x86_64_STANDARD"
      desired_size  = 2
      min_size      = 2
      max_size      = 3
      capacity_type = "ON_DEMAND"
      disk_size     = 30
      labels        = { "workload-type" = "app" }
      taints        = []
    }

    # ── DB : CloudNativePG (Primary 1 + Replica 2) ───────────
    # 🔴 min_size 도 3 이어야 합니다.
    #    CNPG podAntiAffinityType=required → Pod 3개가 서로 다른 노드를 요구.
    #    Pod 3 : 노드 3 이라 여유가 0 이고, 1대만 줄어도 영구 Pending 입니다.
    # 🔴 ON_DEMAND 고정. Spot 회수 시 갈 노드가 없어 복구되지 않습니다.
    "db" = {
      enabled       = true
      instance_type = "t3.small"
      ami_type      = "AL2023_x86_64_STANDARD"
      desired_size  = 3
      min_size      = 3
      max_size      = 3
      capacity_type = "ON_DEMAND"
      disk_size     = 30
      labels        = { "workload-type" = "db" }
      taints = [{
        key    = "workload" # ⚠️ Label 키(workload-type)와 다릅니다. 실물 그대로입니다
        value  = "db"
        effect = "NO_SCHEDULE"
      }]
    }

    # ── GPU-A : 이미지·텍스트 (SGLang, L40S 48GB) ─────────────
    # 🔴 desired_size = 0 · min_size = 0 로 시작합니다.
    #    min 을 1 로 두면 AWS 가 자동으로 1대를 띄워 💰 시간당 $2.29 가 나갑니다.
    # 💰 GPU 2대가 전체 비용의 약 63% 입니다. 안 켜면 $0.
    "gpu-a" = {
      enabled       = true
      instance_type = "g6e.xlarge"
      ami_type      = "AL2023_x86_64_NVIDIA"
      desired_size  = 0
      min_size      = 0
      max_size      = 1
      capacity_type = "ON_DEMAND"
      # AI 모델을 컨테이너 이미지에 포함하기로 해서 이미지가 10GB 이상입니다.
      # 기본 20GB 로는 이미지 하나도 못 받습니다.
      disk_size = 200
      labels = {
        "workload-type" = "gpu"
        "gpu-model"     = "l40s"
      }
      taints = [{
        key    = "nvidia.com/gpu"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
    }

    # ── GPU-B : 챗봇 (Ollama, T4 16GB) ───────────────────────
    "gpu-b" = {
      enabled       = true
      instance_type = "g4dn.xlarge"
      ami_type      = "AL2023_x86_64_NVIDIA"
      desired_size  = 0
      min_size      = 0
      max_size      = 1
      capacity_type = "ON_DEMAND"
      disk_size     = 120
      labels = {
        "workload-type" = "gpu"
        "gpu-model"     = "t4"
      }
      taints = [{
        key    = "nvidia.com/gpu"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
    }
  }
}

variable "nodes_extra_policy_arns" {
  description = <<-EOT
    노드 IAM 역할에 추가로 붙일 관리형 정책.
    기본 4종(WorkerNode·CNI·ECR·SSM)은 모듈이 항상 붙이므로 여기 넣지 않는다.

    🔴 비워 두는 것이 기본입니다. 노드 역할에 권한을 붙이면
       그 노드에 뜬 모든 Pod 가 그 권한을 갖습니다.
       Pod 단위 권한은 ⑧ IRSA 로 줍니다.
  EOT
  type        = list(string)
  default     = []
}

variable "nodes_ssh_key_name" {
  description = <<-EOT
    노드에 넣을 EC2 키페어. null 유지가 원칙입니다.
    🔴 SSH(22)는 설계상 차단이고 접근은 SSM Session Manager 로만 합니다.
  EOT
  type        = string
  default     = null
}

# ------------------------------------------------------------
# ⑧ EKS 애드온 (addons_ 접두사)
# ------------------------------------------------------------

variable "addons_vpc_cni_enable_network_policy" {
  description = <<-EOT
    🔴 EKS 에서 NetworkPolicy 를 실제로 시행할지.

    쿠버네티스에서 NetworkPolicy 는 "선언" 일 뿐이고 실제로 막는 건 CNI 입니다.
    이 값을 끄면 NetworkPolicy 리소스는 정상 생성되지만 아무것도 막지 않고,
    🔴 에러도 경고도 나지 않습니다.

    🔗 CN(박명수님) PR #24 의 NetworkPolicy 전부가 이 값 하나에 달려 있습니다.
  EOT
  type        = bool
  default     = true
}

variable "addons_vpc_cni_version" {
  description = <<-EOT
    VPC CNI 버전. null 이면 클러스터 버전에 맞는 AWS 기본값.
    2026-09-17 확인: k8s 1.35 기준 v1.23.1-eksbuild.1
  EOT
  type        = string
  default     = null
}

variable "addons_manage_coredns_kube_proxy" {
  description = <<-EOT
    CoreDNS·kube-proxy 를 Terraform 관리로 인수할지.
    EKS 가 클러스터 생성 시 자체 설치하는데, 인수하면 버전이 코드에 남아
    팀원이 같은 상태를 재현할 수 있습니다.
  EOT
  type        = bool
  default     = true
}

variable "addons_coredns_version" {
  description = "CoreDNS 버전. null 이면 AWS 기본값."
  type        = string
  default     = null
}

variable "addons_kube_proxy_version" {
  description = "kube-proxy 버전. null 이면 AWS 기본값."
  type        = string
  default     = null
}

variable "addons_ebs_csi_enabled" {
  description = <<-EOT
    🔴 EBS CSI Driver 설치 여부. **IRSA 가 선행조건입니다.**

    없으면 CNPG PVC 가 Pending 에서 멈춰 DB Pod 3개가 안 뜹니다.
    그런데 IRSA 없이 켜도 같은 증상이 나옵니다(권한이 없어 볼륨 생성 실패).

    🔗 박다정님 modules/irsa(PR #32) 머지 후 true 로 바꾸고
       addons_ebs_csi_irsa_role_arn 을 함께 채웁니다.
  EOT
  type        = bool
  default     = false
}

variable "addons_ebs_csi_version" {
  description = <<-EOT
    EBS CSI 버전. null 이면 AWS 기본값.
    2026-09-17 확인: k8s 1.35 기준 v1.66.0-eksbuild.1
  EOT
  type        = string
  default     = null
}

variable "addons_ebs_csi_irsa_role_arn" {
  description = <<-EOT
    EBS CSI 컨트롤러용 IRSA 역할 ARN (kube-system/ebs-csi-controller-sa).
    🔗 박다정님 modules/irsa 출력을 넘깁니다.
  EOT
  type        = string
  default     = null
}

# ------------------------------------------------------------
# s3-images / CloudFront
# ------------------------------------------------------------

variable "images_cloudfront_domain" {
  description = "상품 이미지 CloudFront에 매핑할 도메인"
  type        = string
  default     = "img.stg.midam.store"
}

variable "route53_zone_id" {
  description = "Route53 Hosted Zone ID"
  type        = string
}


# ------------------------------------------------------------
# ⑩ EDGE — ALB / ACM / WAF (환경별 통합 입력)
# ------------------------------------------------------------
variable "alb_domain_name" {
  description = "이 환경의 Backend API 도메인. FE/Vercel 도메인과 구분한다."
  type        = string
  default     = "api.stg.midam.store"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.alb_domain_name))
    error_message = "alb_domain_name에 스킴/경로/와일드카드 없는 소문자 DNS 이름을 입력하세요."
  }
}

variable "alb_zone_id" {
  description = "API 도메인을 관리하는 기존 Public Route53 Hosted Zone ID. 실제 값을 terraform.tfvars로 주입한다(필수)."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^Z[A-Z0-9]+$", var.alb_zone_id))
    error_message = "alb_zone_id에 실제 Hosted Zone ID(Z로 시작)를 입력하세요. 빈 값은 허용하지 않습니다."
  }
}

variable "waf_rule_mode" {
  description = "count로 오탐 관찰 후 담당자 확인을 거쳐 block으로 전환. count는 차단하지 않는다."
  type        = string
  default     = "count"
  nullable    = false

  validation {
    condition     = contains(["count", "block"], var.waf_rule_mode)
    error_message = "waf_rule_mode는 count 또는 block이어야 합니다."
  }
}

variable "waf_managed_rule_groups" {
  description = "ALB용 AWS Managed Rule Group과 중복 없는 우선순위. 기존 모듈 기본 규칙 유지."
  type = list(object({
    name     = string
    priority = number
  }))
  default = [
    { name = "AWSManagedRulesCommonRuleSet", priority = 1 },
    { name = "AWSManagedRulesSQLiRuleSet", priority = 2 },
  ]
  nullable = false

  validation {
    condition = (
      length(var.waf_managed_rule_groups) > 0 &&
      length(distinct([for rule in var.waf_managed_rule_groups : rule.name])) == length(var.waf_managed_rule_groups) &&
      length(distinct([for rule in var.waf_managed_rule_groups : rule.priority])) == length(var.waf_managed_rule_groups) &&
      alltrue([for rule in var.waf_managed_rule_groups : try(
        startswith(rule.name, "AWSManagedRules") && rule.priority >= 0 && floor(rule.priority) == rule.priority,
        false
      )])
    )
    error_message = "AWSManagedRules 규칙을 1개 이상 지정하고, 이름 및 0 이상의 정수 우선순위는 중복 없이 입력하세요."
  }
}

variable "backend_ssm_parameters" {
  description = "backend 앱이 읽는 Parameter Store 키-값 쌍. 실제 값은 로컬 terraform.tfvars(gitignore)에서만 채운다. 경로는 irsa.tf의 backend-sa GetParameter Resource 패턴(/${var.env}/backend/*)과 일치해야 한다."
  type        = map(string)
  sensitive   = true
  default     = {}

  validation {
    condition     = alltrue([for v in values(var.backend_ssm_parameters) : v != "CHANGEME"])
    error_message = "backend_ssm_parameters 에 CHANGEME 값이 남아 있습니다. terraform.tfvars 에서 실제 값으로 교체하세요."
  }
}

variable "ai_ssm_parameters" {
  description = "ai 앱이 읽는 Parameter Store 키-값 쌍. 실제 값은 로컬 terraform.tfvars(gitignore)에서만 채운다. 경로는 irsa.tf의 ai-worker-sa GetParameter Resource 패턴(/${var.env}/ai/*)과 일치해야 한다."
  type        = map(string)
  sensitive   = true
  default     = {}

  validation {
    condition     = alltrue([for v in values(var.ai_ssm_parameters) : v != "CHANGEME"])
    error_message = "ai_ssm_parameters 에 CHANGEME 값이 남아 있습니다. terraform.tfvars 에서 실제 값으로 교체하세요."
  }
}