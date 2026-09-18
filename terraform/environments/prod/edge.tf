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
  # TODO(BE/파트장): SSE용 idle timeout은 미확정. 현재 모듈/AWS 기본60초 유지.
}
