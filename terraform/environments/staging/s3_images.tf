# [s3-images] jangin-{env}-s3-images 버킷 + CloudFront(OAC) + ACM(us-east-1)

module "s3_images" {
  source = "../../modules/s3"

  bucket_name = "${var.project}-${var.env}-s3-images"

  cors_allowed_origins = ["https://stg.midam.store", "http://localhost:3000"]

  enable_logging        = true
  logging_target_bucket = module.s3_access.bucket_id

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
