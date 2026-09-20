# [s3-backup] jangin-{env}-s3-backup — CNPG WAL·백업, 비공개, SSE-KMS(CMK)

module "s3_backup" {
  source = "../../modules/s3"

  bucket_name = "${var.project}-${var.env}-s3-backup"
  kms_key_arn = module.kms_app.key_arn

  enable_logging        = true
  logging_target_bucket = module.s3_access.bucket_id

  versioning_enabled = true

  lifecycle_rules = [
    {
      id                                 = "backup-noncurrent-version-expire"
      noncurrent_version_expiration_days = 30
    },
  ]
}

resource "aws_s3_bucket_policy" "backup" {
  bucket = module.s3_backup.bucket_id
  policy = module.s3_backup.policy_json

  depends_on = [module.s3_backup]
}
