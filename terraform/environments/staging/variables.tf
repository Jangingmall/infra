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

# TODO(staging 값 확정): 박명수/플랫폼: Kubernetes 버전 1.33은 prod 잠정값, staging 적용 전 지원 범위 확인
variable "eks_cluster_version" {
  description = <<-EOT
    🔴 TODO(9/16 확정) — 쿠버네티스 버전. 되돌릴 수 없는 결정입니다.

    확인 명령:
      aws eks describe-cluster-versions --region ap-northeast-2 --profile jangin --output table
    선택 기준: STANDARD_SUPPORT 이면서 AWS 기본(default) 인 버전
      · 최신 버전은 ALB Controller·CNPG·Argo Rollouts·nvidia-device-plugin 이 미대응일 수 있음
      · 확장 지원 구간은 시간당 추가 요금 (예산 98.8% 소진 상태라 회피 필수)
    🔗 박명수님 — 위 4개 부품의 k8s 지원 범위 확인 필요

    아래 값은 **잠정값**입니다. 9/18 apply 전에 반드시 확정값으로 교체하세요.
  EOT
  type        = string
  default     = "1.33"
}

# TODO(staging 값 확정): 박다정: API_AND_CONFIG_MAP 인증 모드 확정
variable "eks_authentication_mode" {
  description = <<-EOT
    🔴 TODO(9/16 확정 · 박다정님) — 클러스터 접근 권한 명부 위치.

    인프라 권고: API_AND_CONFIG_MAP → 9/21 보안 검수 전 API 로 축소
      · 좁히는 방향으로만 변경 가능하므로 넓은 쪽에서 시작해야 선택지가 남음
      · 팀원 대부분이 보는 인터넷 자료가 아직 aws-auth 기준이라 API 전용은 혼선 발생
      · 검수 전 API 로 좁히면 "레거시 인증 경로 제거" 라는 보안 개선 항목이 생김
  EOT
  type        = string
  default     = "API_AND_CONFIG_MAP"
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

# TODO(staging 값 확정): 보안팀: staging API 공개 접근 여부 확인
variable "eks_endpoint_public_access" {
  description = <<-EOT
    🟡 TODO(9/16 확정 · 보안팀) — 컨트롤플레인 API 인터넷 접근 허용 여부.
    "공개"라도 인증 명부에 없으면 401 입니다. Public = 무방비가 아닙니다.
  EOT
  type        = bool
  default     = true
}

variable "eks_endpoint_private_access" {
  description = "VPC 내부 접근 허용. 노드 ↔ 컨트롤플레인 통신 안정성을 위해 true 권장."
  type        = bool
  default     = true
}

# TODO(staging 값 확정): 보안팀: prod 잠정 전체 허용 유지; 감사 로그/최소 인증 권한 전제와 staging 허용 CIDR 확정
variable "eks_public_access_cidrs" {
  description = <<-EOT
    🟡 public 접근 허용 CIDR.
    팀원 6명이 고정 IP 가 아니라 제한이 현실적으로 운영 불가 → 잠정 전체 허용.
    상쇄 조치: 감사 로그 활성화 + 인증 명부 최소화 + 9/21 전 API 모드 축소.
    (보안팀 조건부 승인 요청 대상)
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
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
