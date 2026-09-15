# 공용 ECR은 확정된 단일 state에서만 활성화한다.
module "ecr" {
  source = "../../modules/ecr"

  enabled              = var.ecr_enabled
  env                  = var.ecr_env
  repositories         = var.ecr_repositories
  keep_last_images     = var.ecr_keep_last_images
  untagged_expire_days = var.ecr_untagged_expire_days
  kms_key_arn          = var.ecr_kms_key_arn
  tags                 = var.ecr_tags
}
