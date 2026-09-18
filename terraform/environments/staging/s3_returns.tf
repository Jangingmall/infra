# [s3-returns] jangin-{env}-s3-returns - 반품 증빙, 비공개, SSE-KMS(CMK)

module "s3_returns" {
  source = "../../modules/s3"

  bucket_name = "${var.project}-${var.env}-s3-returns"
  kms_key_arn = module.kms_app.key_arn

  cors_allowed_origins = ["https://stg.midam.store", "http://localhost:3000"]

  logging_target_bucket = "${var.project}-infra-s3-access"

  # lifecycle 없음
}

resource "aws_s3_bucket_policy" "returns" {
  bucket = module.s3_returns.bucket_id
  policy = module.s3_returns.policy_json

  depends_on = [module.s3_returns]
}
