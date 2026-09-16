# ============================================================
# modules/security/variables.tf
# ------------------------------------------------------------
# 이 모듈은 SG 4종(sg-alb / sg-eks-node / sg-db / sg-eks-gpu)과
# 규칙 15개를 만든다. VPC 는 직접 만들지 않고 ID 로 받는다.
# ============================================================

variable "project" {
  description = "프로젝트 식별자 (예: jangin)"
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
  description = <<-EOT
    AWS 리전. S3 관리형 prefix list 이름(com.amazonaws.<region>.s3)을
    조립하는 데 쓴다. prefix list ID(pl-xxxx)는 리전마다 다르므로
    ID 를 하드코딩하지 않고 이름으로 조회한다.
  EOT
  type        = string
}

variable "vpc_id" {
  description = <<-EOT
    SG 를 붙일 VPC ID.
    🔴 modules/network 의 output "vpc_id" 를 받아야 한다.
       이 모듈 안에서 aws_vpc.main.id 를 직접 참조하면
       네트워크 모듈과 한 몸이 되어 재사용이 불가능해진다.
  EOT
  type        = string
}
