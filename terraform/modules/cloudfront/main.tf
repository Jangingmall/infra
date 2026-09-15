# [CloudFront] jangin-{env}-s3-images 앞단
# - S3는 Block Public Access 유지 (Private) - CloudFront(OAC)의 요청만 허용
# - products/* 만 공개 캐시 대상. List/Put/Delete는 이 정책에 포함하지 않음 (BE가 별도 IAM으로 관리)
# - 인증서는 반드시 acm_cloudfront 모듈 출력(us-east-1)을 사용 — 서울 리전 인증서는 붙지 않음

resource "aws_cloudfront_origin_access_control" "this" {
  name                              = "${var.bucket_name}-oac"
  description                       = "OAC for ${var.bucket_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  is_ipv6_enabled = true
  price_class     = var.price_class
  aliases         = [var.domain_name]
  comment         = "${var.bucket_name} - products/* 공개 캐시 (OAC)"

  origin {
    domain_name              = var.bucket_regional_domain_name
    origin_id                = "s3-${var.bucket_name}"
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  default_cache_behavior {
    allowed_methods         = ["GET", "HEAD"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "s3-${var.bucket_name}"
    viewer_protocol_policy   = "redirect-to-https"
    cache_policy_id          = data.aws_cloudfront_cache_policy.optimized.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = var.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# S3는 Private 유지 - CloudFront(이 배포)에서 오는 GET만 허용, ACL/공개 정책 없음
data "aws_iam_policy_document" "oac" {
  statement {
    sid     = "AllowCloudFrontOACGetProducts"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = ["${var.bucket_arn}/products/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "images_oac" {
  bucket = var.bucket_name
  policy = data.aws_iam_policy_document.oac.json
}

resource "aws_route53_record" "cdn_alias" {
  zone_id = var.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}
