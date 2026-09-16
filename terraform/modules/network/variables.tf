# ============================================================
# modules/network/variables.tf — 이 모듈이 "밖에서 받아야 하는 값"
# ------------------------------------------------------------
# 🔴 모듈 변수에는 default 를 두지 않는다. (검수 체크리스트 14)
#    default 가 있으면 environments/ 에서 값을 빠뜨려도 조용히
#    엉뚱한 값으로 만들어진다. 기본값은 environments/*/variables.tf 에만 둔다.
#
# 🔄 2026-09-16: NAT 관련 변수 3종(enable_nat_gateway · nat_gateway_az ·
#    alarm_sns_topic_arns)을 modules/nat 로 옮겼다. (PR #19 파트장 리뷰 반영)
#    이 모듈은 이제 전부 무료 리소스만 다룬다.
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
