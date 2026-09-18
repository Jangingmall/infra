# [aws-waf-logs] aws-waf-logs-jangin - WAF 로그 전용, 비공개

module "s3_waf_logs" {
  source = "../../modules/s3"

  bucket_name = "aws-waf-logs-${var.project}"
  kms_key_arn = module.kms_app.key_arn

  logging_target_bucket = module.s3_access.bucket_id

  lifecycle_rules = [
    {
      id              = "waf-logs-expire"
      expiration_days = 30
    },
  ]
}

resource "aws_s3_bucket_policy" "waf_logs" {
  bucket = module.s3_waf_logs.bucket_id
  policy = module.s3_waf_logs.policy_json

  depends_on = [module.s3_waf_logs]
}
