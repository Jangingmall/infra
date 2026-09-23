# Stage·Prod 공용 AI 모델 가중치 버킷. 생성·정책·로깅은 Prod state에서만 관리한다.
# Stage 제거 시 유지된다. Prod destroy는 공용 버킷도 대상으로 하므로 별도 검토가 필요하다.

module "s3_models" {
  source = "../../modules/s3"

  bucket_name = "${var.project}-${var.env}-s3-models"
  kms_key_arn = null

  enable_logging        = true
  logging_target_bucket = module.s3_access.bucket_id

  # DeleteObject 를 막아도 같은 경로에 PutObject 하면 기존 가중치가 덮어써진다.
  # 버전관리로 덮어쓴 옛 버전을 남겨 복구 경로를 확보한다. (켠 뒤에는 Suspended 로만 전환 가능)
  versioning_enabled = true

  # 옛 버전(noncurrent)만 14일 뒤 삭제한다. 현재 버전에는 expiration 을 두지 않는다.
  # 14일: 노드를 내린 기간(10/1~10/4) 뒤 10/5 에야 오염을 발견해도 복구 가능한 여유
  lifecycle_rules = [
    {
      id                                 = "models-noncurrent-version-expire"
      noncurrent_version_expiration_days = 14
    },
  ]
}

resource "aws_s3_bucket_policy" "models" {
  bucket = module.s3_models.bucket_id
  policy = module.s3_models.policy_json

  depends_on = [module.s3_models]
}
