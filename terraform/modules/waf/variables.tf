# [WAf] 모듈 입력 변수 정의

variable "name" {
  description = "WebACL 이름 (예: jangin-prod-waf-alb, jangin-staging-waf-alb)"
  type        = string
}

variable "scope" {
  description = "REGIONAL(ALB용) | CLOUDFRONT(향후 CloudFront에도 WAF 적용 시, 이 경우 provider는 반드시 us-east-1)"
  type        = string
  default     = "REGIONAL"
}

variable "managed_rule_groups" {
  description = "적용할 AWS Managed Rule Group 목록과 우선순위"
  type = list(object({
    name     = string
    priority = number
  }))
  default = [
    { name = "AWSManagedRulesCommonRuleSet", priority = 1 },
    { name = "AWSManagedRulesSQLiRuleSet", priority = 2 },
  ]
}

variable "rule_mode" {
  description = "count(관찰 모드) | block(차단 모드). 처음엔 count로 배포해 오탐을 확인한 뒤 block으로 전환한다."
  type        = string
  default     = "count"

  validation {
    condition     = contains(["count", "block"], var.rule_mode)
    error_message = "rule_mode는 \"count\" 또는 \"block\" 이어야 합니다."
  }
}

variable "log_destination_arn" {
  description = "WAF 로그를 보낼 S3 버킷 ARN"
  type        = string
}
