variable "github_org" {
  description = "GitHub Organization 또는 사용자명"
  type        = string
}

variable "github_repo" {
  description = "리포지토리 이름"
  type        = string
}

variable "github_subject" {
  description = "sub 클레임에서 'repo:org/repo:' 뒤에 오는 매칭 패턴 (StringLike 대상). 예: environment:production, environment:staging, * (이 리포의 모든 워크플로 허용)"
  type        = string
}

variable "name_suffix" {
  description = "Role 이름 끝에 붙일 구분자 (production, staging, ci 등)"
  type        = string
}

variable "policy_arns" {
  description = "이 Role에 붙일 관리형 정책 ARN 목록"
  type        = list(string)
}