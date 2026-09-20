# [S3] 모듈 입력 변수 정의

variable "bucket_name" {
  description = "버킷 이름. 네이밍 규칙: jangin-<env>-s3-<용도>"
  type        = string
}

variable "tags" {
  description = <<-EOT
    이 버킷에 붙일 태그. providers.tf 의 default_tags 와 자동 merge 되므로
    여기서는 버킷 고유 태그만 넘기면 됨 (예: NodePool)
  EOT
  type        = map(string)
  default     = {}
}

# 암호화
variable "kms_key_arn" {
  description = <<-EOT
    SSE-KMS 로 쓸 CMK ARN. null 이면 SSE-S3(AES256)
      images  → SSE-S3 (null)
      models  → SSE-S3 (null)
      returns → SSE-KMS CMK
      backup  → SSE-KMS CMK
      logs    → SSE-KMS CMK
  EOT
  type        = string
  default     = null
}

# 버전관리
variable "versioning_enabled" {
  description = "버전관리 활성화 여부 (lifecycle 의 noncurrent_version_expiration_days 와 짝으로 쓸 것)"
  type        = bool
  default     = false
}

# lifecycle
variable "lifecycle_rules" {
  description = <<-EOT
    lifecycle 규칙 목록. prefix 별로 여러 개 지정 가능
    필드:
      id                                 규칙 식별자 (버킷 내 유일)
      prefix                             대상 경로. null 이면 버킷 전체
      transition_days / _storage_class   N일 뒤 스토리지 클래스 전환
      expiration_days                    N일 뒤 삭제
      noncurrent_version_expiration_days 구버전 N일 뒤 삭제
  EOT

  type = list(object({
    id                                 = string
    prefix                             = optional(string)
    transition_days                    = optional(number)
    transition_storage_class           = optional(string, "STANDARD_IA")
    expiration_days                    = optional(number)
    noncurrent_version_expiration_days = optional(number)
  }))

  default = []
}

# CORS
variable "cors_allowed_origins" {
  description = "CORS 허용 Origin 목록 (비우면 CORS 설정 자체를 만들지 않음)"
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.cors_allowed_origins, "*")
    error_message = "CORS Origin 에 와일드카드(\"*\")를 사용불가"
  }
}

variable "cors_allowed_methods" {
  description = "CORS 허용 메서드"
  type        = list(string)
  default     = ["PUT"]
}

variable "cors_allowed_headers" {
  description = "CORS 허용 요청 헤더"
  type        = list(string)
  default     = ["Content-Type"]
}

# 접근 로깅
variable "enable_logging" {
  description = "aws_s3_bucket_logging 리소스를 생성할지 여부"
  type        = bool
  default     = false
}

variable "logging_target_bucket" {
  description = "S3 서버 접근 로그를 보낼 대상 버킷 이름"
  type        = string
  default     = null
}

variable "logging_target_prefix" {
  description = "로그 저장 경로. s3-access/ 하위로 모음"
  type        = string
  default     = "s3-access/"
}

# 추가 정책
variable "additional_policy_json" {
  description = "이 버킷 정책에 병합할 추가 IAM 정책 JSON 문서"
  type        = string
  default     = null
}

variable "is_log_destination" {
  description = "이 버킷이 S3 서버 접근 로깅의 대상(target_bucket)으로 쓰이는지 여부. true면 kms_key_arn은 null이어야 함 (AWS 제약)"
  type        = bool
  default     = false
}