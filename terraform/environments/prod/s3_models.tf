# Stage·Prod 공용 AI 모델 가중치 버킷. 생성·정책·로깅은 Prod state에서만 관리한다.
# Stage 제거 시 유지된다. Prod destroy는 공용 버킷도 대상으로 하므로 별도 검토가 필요하다.

module "s3_models" {
  source = "../../modules/s3"

  bucket_name = "${var.project}-${var.env}-s3-models"
  kms_key_arn = null

  enable_logging        = true
  logging_target_bucket = module.s3_access.bucket_id
}

resource "aws_s3_bucket_policy" "models" {
  bucket = module.s3_models.bucket_id
  policy = module.s3_models.policy_json

  depends_on = [module.s3_models]
}
