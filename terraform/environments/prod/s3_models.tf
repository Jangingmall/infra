# [s3-models] jangin-infra-s3-models - AI 모델 가중치, 비공개, SSE-S3

module "s3_models" {
  source = "../../modules/s3"

  bucket_name = "${var.project}-infra-s3-models"
  kms_key_arn = null

  logging_target_bucket = module.s3_access.bucket_id
}

resource "aws_s3_bucket_policy" "models" {
  bucket = module.s3_models.bucket_id
  policy = module.s3_models.policy_json

  depends_on = [module.s3_models]
}
