provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}

# us-east-1 고정 provider — CloudFront용 ACM 인증서 전용 (modules/acm_cloudfront)
# CloudFront는 us-east-1에서 발급한 인증서만 붙일 수 있어 리전이 리소스 종류에 묶여 있음
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = local.common_tags
  }
}
