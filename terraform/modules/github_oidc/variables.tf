variable "github_org" {
  description = "GitHub Organization 또는 사용자명"
  type        = string
}

variable "github_repo" {
  description = "리포지토리 이름"
  type        = string
}

variable "github_subjects" {
  description = "sub 클레임 매칭 패턴 목록 (StringLike, OR 조건). 'repo:org/repo:' 뒤에 붙는 부분만 적는다. 예: [\"environment:production\"], [\"ref:refs/heads/main\", \"ref:refs/heads/release/*\"]. '*' 단독 사용 금지 — PR 워크플로까지 전부 허용되어 위험."
  type        = list(string)
}

variable "name_suffix" {
  description = "Role 이름 끝에 붙일 구분자 (production, staging, ci 등)"
  type        = string
}

variable "policy_arns" {
  description = "이 Role에 붙일 관리형 정책 ARN 목록"
  type        = list(string)
}