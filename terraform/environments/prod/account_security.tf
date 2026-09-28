# 계정 공통 보안 기준: prod state 단독 소유, 같은 계정/리전의 staging에도 적용.
# 기존 CLI 적용분은 최초 plan/apply 전에 import한다. 절차: ../../../T-20260928-account-security.md
# 계정 ID/리전은 기존 data source/provider를 사용하고, true는 승인된 보안 기준이다.
resource "aws_s3_account_public_access_block" "shared" {
  account_id = data.aws_caller_identity.current.account_id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true

  lifecycle {
    prevent_destroy = true
  }
}

# provider의 var.region 범위. 신규 EBS의 기본 암호화만 관리하며 기본 KMS 키는 유지한다.
# 삭제하면 기본 암호화가 해제되므로 prod 환경 철거 시에도 임의 삭제하지 않는다.
resource "aws_ebs_encryption_by_default" "shared" {
  enabled = true

  lifecycle {
    prevent_destroy = true
  }
}
