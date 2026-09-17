# staging 공통 입력과 ECR 입력. prod B안과 동일한 환경 통합 구조.
variable "project" {
  description = "프로젝트 식별자. 모든 리소스 이름의 맨 앞에 붙는다."
  type        = string
  default     = "jangin"
}

variable "env" {
  description = "환경 구분. 리소스 이름과 Environment 태그에 쓰인다."
  type        = string
  default     = "staging"

  # 오타 방지. "prd" 나 "production" 으로 잘못 쓰면
  # jangin-prd-vpc 같은 리소스가 생기고, IAM 정책의
  # jangin-prod-* 패턴에서 빠져나가 버린다.
  validation {
    condition     = contains(["prod", "staging"], var.env)
    error_message = "env 는 prod 또는 staging 만 허용합니다."
  }
}

variable "region" {
  description = "AWS 리전. 작업 규칙 4에 따라 하드코딩하지 않는다."
  type        = string
  default     = "ap-northeast-2"
}

variable "ecr_enabled" {
  description = "공용 ECR의 단일 관리 환경 확정 후 그 환경에서만 true. 두 환경 동시 활성화 금지"
  type        = bool
  default     = false
  nullable    = false
}

# [ECR] 담당 리소스 입력 변수 정의

variable "ecr_repositories" {
  description = <<-EOT
    생성할 ECR 레포 이름 목록.
    팀 확정(CLAUDE.md 09-10): 단일 레포 jangin-app + 동일 아티팩트 승격 · Immutable.
    이미지는 env 무관 공용(1벌) — 태그로 stg→prod 승격하므로 레포명에 env 미포함.
    ※ AI 전용 레포 추가는 AI 이미지 배포 방식 확정 후 목록에 반영.
    ※ 태그 규칙(sha- vs staging-/prod-)은 blocker #2로 미정 — 확정 후 CI에 반영.
  EOT
  type        = list(string)
  default     = ["jangin-app"]
  nullable    = false
  validation {
    condition = length(distinct(var.ecr_repositories)) == length(var.ecr_repositories) && alltrue([
      for name in var.ecr_repositories : try(length(name) >= 2 && length(name) <= 256 && can(regex("^[a-z0-9]+(([.]|_|__|-+)[a-z0-9]+)*(/[a-z0-9]+(([.]|_|__|-+)[a-z0-9]+)*)*$", name)), false)
    ])
    error_message = "중복 없는 ECR 이름을 입력하세요. 이름은 2~256자이며 AWS repositoryName 패턴을 따라야 합니다."
  }
}

variable "ecr_keep_last_images" {
  description = "레포별 보관할 이미지 최대 개수(초과분 오래된 것부터 삭제)"
  type        = number
  default     = 10
  nullable    = false
  validation {
    condition     = var.ecr_keep_last_images >= 1 && floor(var.ecr_keep_last_images) == var.ecr_keep_last_images
    error_message = "keep_last_images 값은 1 이상의 정수여야 합니다."
  }
}

variable "ecr_untagged_expire_days" {
  description = "untagged 이미지 만료일(일)"
  type        = number
  default     = 7
  nullable    = false
  validation {
    condition     = var.ecr_untagged_expire_days >= 1 && floor(var.ecr_untagged_expire_days) == var.ecr_untagged_expire_days
    error_message = "untagged_expire_days 값은 1 이상의 정수여야 합니다."
  }
}

variable "ecr_kms_key_arn" {
  description = "저장 암호화용 KMS CMK ARN. null이면 AES256(기본). CMK는 보안팀 제공"
  type        = string
  default     = null
}

variable "ecr_tags" {
  description = "추가 공통 태그"
  type        = map(string)
  default     = {}
}
