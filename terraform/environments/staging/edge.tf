# 기존 모듈로 HTTPS ALB + REGIONAL WAF + ACM/DNS를 환경별 생성한다.
# 가정: 인증서는 환경별 API 도메인 단독 발급, WAF는 기존 Count → Block 절차 유지.
# Target 등록은 platform/networking의 TargetGroupBinding 담당(별도 수동 Sync).
module "acm_alb" {
  source = "../../modules/acm_alb"

  domain_name = var.alb_domain_name
  zone_id     = var.alb_zone_id
}

module "waf" {
  source = "../../modules/waf"

  name                = "${local.name}-waf-alb"
  scope               = "REGIONAL"
  rule_mode           = var.waf_rule_mode
  managed_rule_groups = var.waf_managed_rule_groups

  # aws_s3_bucket_policy.waf_logs를 직접 참조해 "버킷 정책이 delivery.logs.amazonaws.com을 먼저 허용한 뒤 로깅을 킴
  log_destination_arn = "arn:aws:s3:::${aws_s3_bucket_policy.waf_logs.bucket}"
}

module "alb" {
  source = "../../modules/alb"

  name                  = "${local.name}-alb"
  vpc_id                = module.network.vpc_id
  public_subnet_ids     = module.network.public_subnet_ids
  alb_security_group_id = module.security.alb_id
  certificate_arn       = module.acm_alb.certificate_arn
  web_acl_arn           = module.waf.web_acl_arn
  domain_name           = var.alb_domain_name
  zone_id               = var.alb_zone_id

  # 기존 모듈 계약: IP target, 8080 /healthz, interval30/timeout5,
  # healthy2/unhealthy3, deregistration30. 관리 포트9090은 노출하지 않는다.
  # SSE(AI 스트리밍)용. AWS 기본 60초로는 추론 응답 도중 끊긴다.
  idle_timeout = 300
}
