# [WAF] 모듈 출력 값 - alb 모듈의 web_acl_association에서 참조

output "web_acl_arn" {
  description = "WebACL ARN"
  value       = aws_wafv2_web_acl.this.arn
}

output "web_acl_id" {
  description = "WebACL ID"
  value       = aws_wafv2_web_acl.this.id
}
