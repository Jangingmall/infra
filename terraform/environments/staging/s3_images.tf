# [s3-images] jangin-{env}-s3-images 버킷 + CloudFront(OAC) + ACM(us-east-1)
# ------------------------------------------------------------
# prod/s3_images.tf 와 내용이 동일합니다 (환경 차이는 var.env/도메인 기본값으로만 갈림).
# 🔴 이 파일은 var.project / var.env / var.region 이 prod와 동일하게
#    이미 선언되어 있다고 가정하고 작성됨 — staging 부트스트랩
#    (providers.tf / versions.tf / variables.tf) 은 별도로 추가될 예정.
#    부트스트랩 전에는 이 환경 자체가 init 되지 않으므로 이 파일도 적용 불가.
#
# 정책 소유권 정리 (modules/s3, modules/cloudfront 리팩터 참고):
#   - s3 모듈 / cloudfront 모듈 둘 다 aws_s3_bucket_policy 리소스를 만들지 않는다.
#   - s3 모듈은 TLS 강제 + additional_policy_json 을 병합한 JSON만 output(policy_json).
#   - cloudfront 모듈은 OAC 허용 문장 JSON만 output(oac_policy_json).
#   - 이 둘을 합쳐 실제 attach하는 aws_s3_bucket_policy 는 여기(root) 한 곳에서만 만든다.
#
# 🟡 7종 버킷 중 images 만 우선 연결. models/returns/backup/logs/access/waf는
#    버킷별 확정값(암호화 방식·lifecycle·CORS 등)이 정리된 뒤 같은 패턴으로 추가.

module "s3_images" {
  source = "../../modules/s3"

  bucket_name = "${var.project}-${var.env}-s3-images"

  # images 버킷은 SSE-S3(kms_key_arn = null 기본값) — CLAUDE.md 암호화 방침

  # CORS ✅ 확정 (FE 회신, CLAUDE.md) — staging은 prod origin 대신 stg 도메인.
  # methods/headers/ExposeHeaders/MaxAge는 s3 모듈 기본값과 이미 일치 — origin만 지정.
  cors_allowed_origins = ["https://stg.midam.store", "http://localhost:3000"]

  # 🟡 TODO: lifecycle 규칙 미정. 상품 이미지는 CloudFront로 상시 서빙되어
  # transition/expiration 대상이 아니라고 보이나, "상품 삭제 시 S3 객체(고아
  # 파일) 정리" 정책은 BE와 아직 합의된 바 없음 — 확정 전 임의로 만들지 않음.

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
