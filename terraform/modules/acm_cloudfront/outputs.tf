# [ACM-CloudFront] 모듈 출력 값 - cloudfront_oac 모듈에서 참조

output "certificate_arn" {
  description = "검증 완료된 ACM 인증서 ARN (us-east-1)"
  value       = aws_acm_certificate_validation.this.certificate_arn
}
