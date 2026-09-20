# [kms-app] jangin-{env}-app CMK — SSE-KMS 쓰는 S3 버킷 공용 (returns·backup·logs·waf-logs)

module "kms_app" {
  source = "../../modules/kms"

  alias_name = "alias/${var.project}-${var.env}-app"
  region     = var.region

  # IRSA 확정 후 Role ARN으로 교체: backend-sa, cnpg-backup-sa, loki-sa, tempo SA
  key_user_role_arns = []

  # VPC Flow Logs/WAF 로깅 - IAM Role이 아니라 AWS 로그 전송 서비스가 직접 씀
  log_delivery_service_principals = ["delivery.logs.amazonaws.com"]
}
