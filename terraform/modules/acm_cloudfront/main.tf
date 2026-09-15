# [ACM-CloudFront] us-east-1(버지니아) 고정 - CloudFront는 이 리전 인증서만 붙일 수 있다.
# 서울 리전 인증서는 CloudFront에 사용 불가 (놓치기 쉬운 지점, 네트워크·계정 설계서 IF_11 참조)
#
#    이 모듈은 provider alias를 내부에서 직접 선언한다 (요청된 방식).
#    리전이 환경(prod/staging)과 무관하게 항상 us-east-1로 고정이라 가능한 패턴이지만,
#    Terraform 공식 권장은 아님 — 이 모듈을 for_each/count로 여러 번 인스턴스화하거나
#    다른 AWS 계정에 재사용할 계획이 생기면, 그때는 root에서 configuration_aliases로
#    provider를 넘기는 방식으로 리팩터링해야 한다. (지금 범위: env당 1회 호출이라 안전)

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

resource "aws_acm_certificate" "this" {
  provider = aws.us_east_1

  domain_name               = var.domain_name
  subject_alternative_names = var.subject_alternative_names
  validation_method          = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# Route53은 글로벌 서비스라 root의 기본 provider(ap-northeast-2)로 생성해도 무방
resource "aws_route53_record" "validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = var.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}
