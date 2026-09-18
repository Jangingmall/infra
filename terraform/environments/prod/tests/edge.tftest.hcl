# terraform >= 1.11: 각 environments/{staging,prod}에서
# terraform test
# 모든 provider/기반 모듈을 mock 처리하며 AWS 리소스를 만들지 않는다.
mock_provider "aws" {
  override_during = plan
  mock_resource "aws_acm_certificate" {
    override_during = plan
    defaults = {
      arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"
      domain_validation_options = [{
        domain_name           = "api.midam.store"
        resource_record_name  = "_test.api.midam.store"
        resource_record_type  = "CNAME"
        resource_record_value = "_test.acm-validations.aws."
      }]
    }
  }
  mock_resource "aws_acm_certificate_validation" {
    defaults = { certificate_arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/00000000-0000-0000-0000-000000000000" }
  }
  mock_resource "aws_wafv2_web_acl" {
    defaults = { arn = "arn:aws:wafv2:ap-northeast-2:123456789012:regional/webacl/test/00000000-0000-0000-0000-000000000000" }
  }
  mock_resource "aws_lb" {
    defaults = {
      arn      = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/app/test/0000000000000000"
      dns_name = "test.ap-northeast-2.elb.amazonaws.com"
      zone_id  = "ZTESTALB"
    }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:targetgroup/test/0000000000000000" }
  }
}
mock_provider "tls" {}
mock_provider "aws" {
  alias = "us_east_1"
}

override_module {
  target = module.network
  outputs = {
    vpc_id                  = "vpc-0123456789abcdef0"
    public_subnet_ids       = ["subnet-00000000000000001", "subnet-00000000000000002"]
    app_subnet_ids_by_az    = { a = "subnet-00000000000000003" }
    public_subnet_ids_by_az = { a = "subnet-00000000000000001" }
  }
}
override_module {
  target  = module.security
  outputs = { alb_id = "sg-0123456789abcdef0" }
}
override_module { target = module.nat }
override_module { target = module.endpoints }
override_module { target = module.eks }
override_module { target = module.eks_nodes }
override_module { target = module.eks_addons }
override_module { target = module.ecr }


# 최신 main의 S3/CDN은 이 EDGE 테스트 대상이 아니므로 외부 기반으로 격리한다.
override_module {
  target = module.s3_images
  outputs = {
    bucket_id   = "test-images"
    policy_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }
}
override_module { target = module.acm_cloudfront_images }
override_module { target = module.cloudfront_images }

variables {
  alb_zone_id     = "ZTESTONLY123"
  route53_zone_id = "ZTESTONLY123"
}

run "count_and_native_handoff" {
  command = plan
  assert {
    condition = (
      output.backend_networking.targetGroupARN == "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:targetgroup/test/0000000000000000" &&
      output.backend_networking.vpcID == "vpc-0123456789abcdef0" &&
      toset(output.backend_networking.albSourceCidrs) == toset(var.env == "prod" ? ["10.0.0.0/24", "10.0.1.0/24"] : ["10.1.0.0/24", "10.1.1.0/24"])
    )
    error_message = "TGB에 전달할 TG/VPC/ALB subnet CIDR가 환경과 다릅니다."
  }
  assert {
    condition     = var.alb_domain_name == (var.env == "prod" ? "api.midam.store" : "api.stg.midam.store")
    error_message = "환경별 API 도메인이 다릅니다."
  }
}

run "block_mode" {
  command = plan
  variables { waf_rule_mode = "block" }
}

run "missing_zone_rejected" {
  command = plan
  variables { alb_zone_id = "" }
  expect_failures = [var.alb_zone_id]
}

run "invalid_mode_rejected" {
  command = plan
  variables { waf_rule_mode = "allow" }
  expect_failures = [var.waf_rule_mode]
}

run "duplicate_priority_rejected" {
  command = plan
  variables {
    waf_managed_rule_groups = [
      { name = "AWSManagedRulesCommonRuleSet", priority = 1 },
      { name = "AWSManagedRulesSQLiRuleSet", priority = 1 },
    ]
  }
  expect_failures = [var.waf_managed_rule_groups]
}

run "invalid_domain_rejected" {
  command = plan
  variables { alb_domain_name = "https://api.example.com/path" }
  expect_failures = [var.alb_domain_name]
}
