# ============================================================
# modules/endpoints/variables.tf
# ------------------------------------------------------------
# S3 Gateway Endpoint 를 만들고, 지정된 라우팅 테이블에 연결한다.
# Gateway Endpoint 는 "라우팅 테이블에 경로를 한 줄 추가"하는 방식이라
# 시간당 요금이 없다(무료). Interface Endpoint(ENI 방식)와 다르다.
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
  description = "AWS 리전. 서비스 이름 com.amazonaws.<region>.s3 조립에 쓴다."
  type        = string
}

variable "vpc_id" {
  description = "Endpoint 를 만들 VPC ID. modules/network 의 output vpc_id 를 받는다."
  type        = string
}

variable "route_table_ids" {
  description = <<-EOT
    Endpoint 를 연결할 라우팅 테이블. { 키 = 라우팅테이블ID } 형태.

    🔴 여기에 public 라우팅 테이블을 넣지 않는 것이 설계 의도다.
       1. public 에는 ALB 만 있고 ALB 는 AWS 관리형이라
          우리 라우팅 테이블을 타고 S3 에 가지 않는다.
       2. public 은 IGW 직행인데 동일 리전 S3행은 IGW 경유라도 무료다.
       → 붙일 이유가 없다.

    ⚠️ 키(app / data)가 곧 Terraform 주소의 인덱스가 된다.
       키를 바꾸면 기존 리소스가 destroy + create 되므로 바꾸지 말 것.
  EOT
  type        = map(string)
}
