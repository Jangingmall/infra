output "topic_arn" {
  description = "경보 SNS 토픽 ARN."
  value       = aws_sns_topic.alerts.arn
}

output "rule_names" {
  description = "만들어진 EventBridge 규칙 이름."
  value       = [for r in aws_cloudwatch_event_rule.this : r.name]
}

output "pending_subscriptions" {
  description = "이메일 구독 수. apply 후 수신자가 확인 메일을 눌러야 전달된다."
  value       = length(var.alert_emails)
}
