# 계정 ID 하드코딩 금지(작업 규칙 2) — s3_logs.tf·s3_waf_logs.tf의 로그 전송
# 서비스(delivery.logs.amazonaws.com) 버킷 정책에서 aws:SourceAccount 조건에 사용
data "aws_caller_identity" "current" {}

locals {
  name = "${var.project}-${var.env}"

  common_tags = {
    Project     = var.project
    Environment = var.env
    ManagedBy   = "Terraform"
    Owner       = "infra"
  }
}
