module "ecr" {
  source = "../../modules/ecr"

  enabled              = var.ecr_enabled
  env                  = var.env
  repositories         = var.ecr_repositories
  keep_last_images     = var.ecr_keep_last_images
  untagged_expire_days = var.ecr_untagged_expire_days
  kms_key_arn          = var.ecr_kms_key_arn
  tags                 = var.ecr_tags
}
