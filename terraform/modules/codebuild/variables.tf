# [codebuild] 모듈 입력 변수 정의

variable "name" {
  description = "CodeBuild 프로젝트 이름. 워크플로 runs-on 라벨(codebuild-<name>-...)에 사용"
  type        = string
}

variable "github_repo_url" {
  description = "러너를 붙일 GitHub 레포 URL (https://github.com/<org>/<repo>.git)"
  type        = string
}

variable "connection_arn" {
  description = "콘솔에서 만든 CodeConnections(GitHub App) 연결 ARN"
  type        = string
}

variable "compute_type" {
  description = "빌드 머신 사양. LARGE = 8 vCPU / 15GB / 디스크 128GB"
  type        = string
  default     = "BUILD_GENERAL1_LARGE"
}

variable "image" {
  description = "빌드 환경 이미지 (AWS 관리형)"
  type        = string
  default     = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
}

variable "build_timeout_minutes" {
  description = "빌드 1회 최대 시간(분). 예상 20분 + 여유"
  type        = number
  default     = 60
}

variable "log_retention_days" {
  description = "CloudWatch 로그 보존 기간"
  type        = number
  default     = 7
}

variable "extra_policy_arns" {
  description = "CodeBuild 역할에 추가로 붙일 정책. 워크플로가 OIDC 대신 러너 자격증명을 쓸 때만 사용"
  type        = list(string)
  default     = []
}
