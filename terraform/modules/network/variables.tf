# ============================================================
# modules/network/variables.tf — 이 모듈이 "밖에서 받아야 하는 값"
# ------------------------------------------------------------
# 🔴 모듈 변수에는 default 를 두지 않는다.
#    default 가 있으면 environments/ 에서 값을 빠뜨려도 조용히
#    엉뚱한 값으로 만들어진다. 기본값은 environments/*/variables.tf 에만 둔다.
# ============================================================

variable "project" {
  description = "프로젝트 식별자. 모든 리소스 이름의 맨 앞에 붙는다. (예: jangin)"
  type        = string
}

variable "env" {
  description = "환경 구분. prod | staging"
  type        = string

  validation {
    condition     = contains(["prod", "staging"], var.env)
    error_message = "env 는 prod 또는 staging 만 허용합니다."
  }
}

variable "region" {
  description = "AWS 리전. AZ 이름을 조립하는 데 쓴다. (작업 규칙 4 — AZ 하드코딩 금지)"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR. prod = 10.0.0.0/16 / staging = 10.1.0.0/16"
  type        = string
}

variable "az_suffixes" {
  description = "사용할 AZ 접미사 목록. region 과 합쳐 실제 AZ 이름이 된다. (예: [\"a\", \"c\"])"
  type        = list(string)
}

variable "subnet_cidrs" {
  description = <<-EOT
    tier별 · AZ별 서브넷 CIDR.
    🔴 app 계층만 /20 — EKS VPC CNI가 Pod마다 VPC 실제 IP를 하나씩 쓰기 때문.
       CIDR은 생성 후 변경 불가. /24 로 "정리"하지 말 것. (검수 체크리스트 #1)
  EOT
  type = object({
    public = map(string)
    app    = map(string)
    data   = map(string)
  })
}

variable "cluster_name" {
  description = "EKS 클러스터 이름. 서브넷의 kubernetes.io/cluster/<이름> 태그에 쓰인다."
  type        = string
}

# ------------------------------------------------------------
# ⑤ NAT Gateway
# ------------------------------------------------------------

variable "enable_nat_gateway" {
  description = <<-EOT
    NAT Gateway 생성 여부.
    false 로 두면 NAT 와 app 라우팅 경로만 사라지고 EIP 는 남는다.
    → 10/1~10/4 환경을 내릴 때 값 하나로 비용을 끊되,
      스마트택배 allowlist 에 등록된 공인 IP 는 유지된다. (작업 규칙 12)
  EOT
  type        = bool
}

variable "nat_gateway_az" {
  description = <<-EOT
    NAT Gateway 를 둘 AZ 접미사. az_suffixes 안의 값이어야 한다.
    MVP 는 AZ-a 단일이며, 이 경우 해당 AZ 장애 시 아웃바운드 전체가 끊긴다
    (보안팀 NAT 승인 조건 #5 — 문서화 대상).
    멀티 AZ NAT 로 가려면 app 라우팅 테이블도 AZ 별로 쪼개야 한다.
  EOT
  type        = string
}

variable "alarm_sns_topic_arns" {
  description = <<-EOT
    CloudWatch 알람이 알림을 보낼 SNS 토픽 ARN 목록.
    🟡 Budget 알림 SNS 재사용 여부가 미확정이라 기본은 빈 목록으로 둔다.
       빈 목록이면 지표·알람 상태는 정상 동작하고 알림만 나가지 않는다.
  EOT
  type        = list(string)
}
