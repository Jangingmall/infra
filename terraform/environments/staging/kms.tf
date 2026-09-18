# [kms-app] jangin-staging-app CMK - SSE-KMS 쓰는 이 환경 소유 S3 버킷용 (returns/backup)

module "kms_app" {
  source = "../../modules/kms"

  alias_name = "alias/${var.project}-${var.env}-app"

  # IRSA 확정 후 Role ARN으로 교체: backend-sa, cnpg-backup-sa
  key_user_role_arns = []

  log_delivery_service_principals = []
}
