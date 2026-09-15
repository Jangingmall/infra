# [ACM-ALB] 모듈 입력 변수 정의

variable "domain_name" {
  description = "ALB에 연결할 도메인 (예: api.midam.store, api.stg.midam.store)"
  type        = string
}

variable "subject_alternative_names" {
  description = "SAN으로 추가할 도메인 목록 (필요 시)"
  type        = list(string)
  default     = []
}

variable "zone_id" {
  description = "DNS 검증 레코드를 생성할 Route53 Hosted Zone ID (콘솔에서 등록한 도메인의 zone)"
  type        = string
}
