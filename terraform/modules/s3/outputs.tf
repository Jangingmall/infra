# [S3] 모듈 출력 값

output "bucket_id" {
  description = "버킷 이름"
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "버킷 ARN"
  value       = aws_s3_bucket.this.arn
}

output "bucket_regional_domain_name" {
  description = "리전 도메인 - CloudFront origin 전달"
  value       = aws_s3_bucket.this.bucket_regional_domain_name
}

output "policy_json" {
  description = "TLS 강제 + additional_policy_json 이 병합된 최종 버킷 정책 문서(JSON)"
  value       = data.aws_iam_policy_document.this.json
}
