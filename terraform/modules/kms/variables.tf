# [KMS] 모듈 입력 변수 정의

variable "alias_name" {
  description = "키 별칭. 형식: alias/jangin-<env>-app"
  type        = string
  nullable    = false
}

variable "description" {
  description = "KMS 키"
  type        = string
  default     = "jangin app CMK - S3(returns/backup/logs/waf-logs) SSE-KMS 공용"
  nullable    = false
}

variable "deletion_window_in_days" {
  description = "키 삭제 대기 기간"
  type        = number
  default     = 30
  nullable    = false

  validation {
    condition     = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
    error_message = "deletion_window_in_days 는 7~30 사이여야 합니다 (AWS 제약)."
  }
}

variable "key_user_role_arns" {
  description = "이 CMK로 암/복호화할 IAM Role ARN 목록 (IRSA Role 등). 확정 전까지 빈 리스트로 둘 것"
  type        = list(string)
  nullable    = false
}

variable "log_delivery_service_principals" {
  description = "이 키로 S3에 로그를 직접 쓰는 AWS 서비스 프린시펄 목록. 필요 없으면 빈 리스트"
  type        = list(string)
  default     = []
  nullable    = false
}

variable "tags" {
  description = "태그. providers.tf 의 default_tags 와 자동 merge 되므로 이 키 고유 태그만 넘기면 됨"
  type        = map(string)
  default     = {}
  nullable    = false
}
