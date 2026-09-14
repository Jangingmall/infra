# [ECR] 모듈 출력 값 - 다른 모듈/환경에서 참조
# IAM 담당(박다정)은 repository_arns로 push(OIDC 역할)·pull(노드) 권한을 부여.
# CI(각 앱 레포)는 repository_urls로 docker push 대상 주소를 참조.

output "repository_urls" {
  description = "레포명 => ECR URL (docker push 대상)"
  value       = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

output "repository_arns" {
  description = "레포명 => ARN (IAM 정책 Resource 스코프용)"
  value       = { for k, r in aws_ecr_repository.app : k => r.arn }
}

output "registry_id" {
  description = "ECR 레지스트리(계정) ID"
  value       = try(values(aws_ecr_repository.app)[0].registry_id, null)
}
