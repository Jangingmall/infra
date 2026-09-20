output "role_arn" {
  description = "GitHub Actions 워크플로가 assume할 Role ARN"
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "GitHub Actions 워크플로가 assume할 Role 이름"
  value       = aws_iam_role.this.name
}

