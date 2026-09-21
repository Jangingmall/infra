# [ALB] 사용자 → WAF → ALB(TLS 종료) → App Pod(target-type=ip, 8080)
# - 관리 포트(9090)는 타깃그룹/리스너 어디에도 노출하지 않는다 (작업 규칙 #6)
# - health check는 Backend 값을 그대로 따르고(8080 /healthz),
#   deregistration_delay=30s는 BE graceful shutdown(30s)과 짝을 맞춘 값 (기본 300s 아님)
# - SG는 이 모듈 밖(기존 flat 리소스 또는 추후 security_group 모듈)에서 생성된 것을
#   변수로 전달받는다 — 이 모듈은 SG를 직접 만들지 않는다.

resource "aws_lb" "this" {
  name               = var.name
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

  idle_timeout = var.idle_timeout
}

resource "aws_lb_target_group" "app" {
  name        = "${var.name}-tg"
  port        = var.target_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = var.health_check_path
    port                = var.target_port
    healthy_threshold   = var.healthy_threshold
    unhealthy_threshold = var.unhealthy_threshold
    timeout             = var.health_check_timeout
    interval            = var.health_check_interval
    matcher             = "200"
  }

  deregistration_delay = var.deregistration_delay
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_wafv2_web_acl_association" "this" {
  resource_arn = aws_lb.this.arn
  web_acl_arn  = var.web_acl_arn
}

resource "aws_route53_record" "alb_alias" {
  zone_id = var.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
