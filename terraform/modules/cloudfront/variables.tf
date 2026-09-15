# [CloudFront] 모듈 입력 변수 정의

variable "bucket_name" {
  description = "대상 S3 버킷 이름 (예: jangin-prod-s3-images)"
  type        = string
}

variable "bucket_arn" {
  type = string
}

variable "bucket_regional_domain_name" {
  description = "aws_s3_bucket.images.bucket_regional_domain_name 값을 전달"
  type        = string
}

variable "domain_name" {
  description = "CloudFront에 매핑할 도메인 (예: img.midam.store) — 확정 필요"
  type        = string
}

variable "certificate_arn" {
  description = "acm_cloudfront 모듈 출력 (us-east-1 ACM ARN)"
  type        = string
}

variable "zone_id" {
  type = string
}

variable "price_class" {
  description = "PriceClass_100(북미/유럽) | PriceClass_200(+아시아) | PriceClass_All"
  type        = string
  default     = "PriceClass_200"
}
