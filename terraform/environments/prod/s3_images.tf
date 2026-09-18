# [s3-images] jangin-{env}-s3-images 버킷 + CloudFront(OAC) + ACM(us-east-1)
# ------------------------------------------------------------
# 정책 소유권 정리 (modules/s3, modules/cloudfront 리팩터 참고):
#   - s3 모듈 / cloudfront 모듈 둘 다 aws_s3_bucket_policy 리소스를 만들지 않는다.
#   - s3 모듈은 TLS 강제 + additional_policy_json 을 병합한 JSON만 output(policy_json).
#   - cloudfront 모듈은 OAC 허용 문장 JSON만 output(oac_policy_json).
#   - 이 둘을 합쳐 실제 attach하는 aws_s3_bucket_policy 는 여기(root) 한 곳에서만 만든다.
#
# 의존 순서: s3_images(버킷 생성) → cloudfront_images(OAC/배포, s3_images의
# bucket_arn 등을 입력으로 받음) → s3_images 의 additional_policy_json 에
# cloudfront_images 의 oac_policy_json 을 다시 넣음(모듈 선언 순서와 무관하게
# HCL이 알아서 의존 그래프를 푼다) → 마지막으로 정책 리소스 attach.

module "s3_images" {
  source = "../../modules/s3"

  bucket_name = "${var.project}-${var.env}-s3-images"

  # s3 모듈 기본값(PUT · Content-Type · ETag · 3000) - origin만 
  cors_allowed_origins = ["https://midam.store", "http://localhost:3000"]

  additional_policy_json = module.cloudfront_images.oac_policy_json
}

resource "aws_s3_bucket_policy" "images" {
  bucket = module.s3_images.bucket_id
  policy = module.s3_images.policy_json

  # module.s3_images 내부의 public_access_block 등이 먼저 적용되도록
  # 모듈 전체에 대한 의존을 명시 (s3 모듈이 더 이상 이 순서를 스스로 보장하지 않음)
  depends_on = [module.s3_images]
}

module "acm_cloudfront_images" {
  source = "../../modules/acm_cloudfront"

  # CloudFront ACM은 us-east-1 고정 — providers.tf 의 aws.us_east_1 을 전달
  providers = {
    aws.us_east_1 = aws.us_east_1
  }

  domain_name = var.images_cloudfront_domain
  zone_id     = var.route53_zone_id
}

module "cloudfront_images" {
  source = "../../modules/cloudfront"

  bucket_name                 = module.s3_images.bucket_id
  bucket_arn                  = module.s3_images.bucket_arn
  bucket_regional_domain_name = module.s3_images.bucket_regional_domain_name

  domain_name     = var.images_cloudfront_domain
  certificate_arn = module.acm_cloudfront_images.certificate_arn
  zone_id         = var.route53_zone_id
}
