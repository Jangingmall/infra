# 루트 output을 통해 CI 및 담당자에게 전달한다.
# 같은 루트의 다른 모듈은 module.ecr.repository_arns 등을 입력으로 참조한다.
output "ecr_repository_urls" {
  description = "레포명 => ECR URL (docker push 대상)"
  value       = module.ecr.repository_urls
}

output "ecr_repository_arns" {
  description = "레포명 => ARN (IAM 정책 Resource 스코프용)"
  value       = module.ecr.repository_arns
}

output "ecr_registry_id" {
  description = "ECR 레지스트리(계정) ID"
  value       = module.ecr.registry_id
}

output "irsa_role_arns" {
  value = { for k, m in module.irsa : k => m.role_arn }
}