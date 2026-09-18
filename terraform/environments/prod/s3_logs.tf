# [s3-logs] jangin-infra-s3-logs - vpc-flow/loki/tempo prefix 3종, 비공개, SSE-KMS(CMK)

module "s3_logs" {
  source = "../../modules/s3"

  bucket_name = "${var.project}-infra-s3-logs"
  kms_key_arn = module.kms_app.key_arn

  logging_target_bucket = module.s3_access.bucket_id

  lifecycle_rules = [
    {
      id              = "vpc-flow-expire"
      prefix          = "vpc-flow/"
      expiration_days = 30
    },
    {
      id              = "loki-expire"
      prefix          = "loki/"
      expiration_days = 30
    },
    {
      # tempo 자체 기본 보관은 14일이지만, 다른 prefix와 맞춰 30일로 둔다
      id              = "tempo-expire"
      prefix          = "tempo/"
      expiration_days = 30
    },
  ]
}

resource "aws_s3_bucket_policy" "logs" {
  bucket = module.s3_logs.bucket_id
  policy = module.s3_logs.policy_json

  depends_on = [module.s3_logs]
}
