# [CloudFront] 모듈 출력 값
# BE 담당(image-base-url)이 Parameter Store에서 이 도메인을 참조 (코드 변경 없이 값만 교체)

output "distribution_id" {
  value = aws_cloudfront_distribution.this.id
}

output "distribution_domain_name" {
  value = aws_cloudfront_distribution.this.domain_name
}

output "distribution_arn" {
  value = aws_cloudfront_distribution.this.arn
}
