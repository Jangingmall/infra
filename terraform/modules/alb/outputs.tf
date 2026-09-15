# [ALB] 모듈 출력 값

output "alb_arn" {
  value = aws_lb.this.arn
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "target_group_arn" {
  description = "BE 배포(Rollout)에서 blueGreen active/preview 서비스와 연결 시 참조"
  value       = aws_lb_target_group.app.arn
}
