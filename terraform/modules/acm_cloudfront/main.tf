# [ACM-CloudFront] us-east-1(버지니아) 고정 - CloudFront는 이 리전 인증서만 붙일 수 있다.
# 서울 리전 인증서는 CloudFront에 사용 불가 (놓치기 쉬운 지점, 네트워크·계정 설계서 IF_11 참조)
#
# 모듈이 provider를 직접 선언하지 않는다. 대신 configuration_aliases로 
# "us_east_1이라는 이름의 provider를 호출 측에서 넘겨받겠다"는 자리만
# 선언하고, 실제 provider(region=us-east-1)는 root(environments/*/providers.tf)
# 에서 만들어 이 모듈 호출 시 providers = { aws.us_east_1 = aws.us_east_1 }로 전달

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = ">= 5.0"
      configuration_aliases = [aws.us_east_1]
    }
  }
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
