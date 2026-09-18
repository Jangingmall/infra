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

output "oac_policy_json" {
  description = "OAC가 이 버킷의 products/* 를 읽도록 허용하는 정책 문서(JSON)"
  value       = data.aws_iam_policy_document.oac.json
}
