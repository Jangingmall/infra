# environments/prod/kms.tf
# ⑧ 프로젝트 공용 CMK — SSM SecureString + S3(returns/backup/logs/waf) 암호화
# 🔴 State 전용 CMK(alias/jangin-infra-s3-tfstate, bootstrap-tfstate.sh 생성)와는
#    반드시 별개 키 — bootstrap-tfstate.sh 3번 섹션 순환 의존 설명 참고
resource "aws_kms_key" "shared" {
  description             = "${var.project}-${var.env} 공용 CMK — SecureString/S3(returns·backup·logs·waf) 암호화"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Project   = var.project
    Env       = var.env
    ManagedBy = "Terraform"
    Purpose   = "shared-encryption"
  }
}

resource "aws_kms_alias" "shared" {
  name          = "alias/${var.project}-${var.env}-shared"
  target_key_id = aws_kms_key.shared.key_id
}