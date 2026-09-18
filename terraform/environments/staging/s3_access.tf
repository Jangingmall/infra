# [s3-access] jangin-{env}-s3-access - S3 서버 접근 로그 전용, 비공개, SSE-S3(KMS 금지)

module "s3_access" {
  source = "../../modules/s3"

  bucket_name        = "${var.project}-${var.env}-s3-access"
  kms_key_arn        = null
  is_log_destination = true

  lifecycle_rules = [
    {
      id              = "access-expire"
      expiration_days = 30
    },
  ]
}

resource "aws_s3_bucket_policy" "access" {
  bucket = module.s3_access.bucket_id
  policy = module.s3_access.policy_json

  depends_on = [module.s3_access]
}
