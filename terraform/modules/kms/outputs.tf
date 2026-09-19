# [KMS] 모듈 출력 값

output "key_arn" {
  description = "CMK ARN - s3 모듈의 kms_key_arn, IRSA 모듈의 kms:Decrypt resources 등에 전달"
  value       = aws_kms_key.this.arn
}

output "key_id" {
  description = "CMK ID"
  value       = aws_kms_key.this.key_id
}

output "alias_arn" {
  description = "키 별칭 ARN"
  value       = aws_kms_alias.this.arn
}

output "alias_name" {
  description = "키 별칭 이름 (alias/... 형식) — 다른 모듈이 ARN 대신 별칭으로 참조할 때"
  value       = aws_kms_alias.this.name
}
