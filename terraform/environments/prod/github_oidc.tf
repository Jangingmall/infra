# ============================================================
# github_oidc.tf — GitHub Actions OIDC 인증 (prod)
# ------------------------------------------------------------
# 🔴 전제조건: scripts/bootstrap-github-oidc.sh 최초 1회 실행.
#    staging에서 이미 실행했다면 다시 실행할 필요 없음
#    (같은 계정, 같은 Provider를 조회만 하는 구조).
#
# 🔴 GitHub 리포지토리 Settings → Environments → "prod"에
#    Required reviewers 보호 규칙을 반드시 걸어두세요.
#    이 Role은 PowerUserAccess+IAMFullAccess라는 넓은 권한을 가지므로,
#    "prod는 인프라팀 경유" 정책을 여기서 실질적으로 강제하는 지점입니다.
# ============================================================
data "aws_caller_identity" "current" {}

module "github_oidc" {
  source = "../../modules/github_oidc"

  github_org      = "Jangingmall"
  github_repo     = "infra"
  github_subjects = ["environment:prod"]
  name_suffix     = "prod"

  policy_arns = [
    "arn:aws:iam::aws:policy/PowerUserAccess",
    "arn:aws:iam::aws:policy/IAMFullAccess",
  ]
}
output "github_actions_role_arn" { value = module.github_oidc.role_arn }

# ---- Backend 팀 CI (ECR push, main 브랜치만 허용) ----
resource "aws_iam_policy" "gha_backend_ecr" {
  name = "jangin-gha-backend-ecr-push"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Effect = "Allow"
        Action = ["ecr:BatchCheckLayerAvailability", "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload"]
        Resource = "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/jangin-app"
      }
    ]
  })
}

module "github_oidc_backend" {
  source = "../../modules/github_oidc"

  github_org      = "Jangingmall"
  github_repo     = "backend"
  github_subjects = ["ref:refs/heads/*"]
  name_suffix     = "ci"

  policy_arns = [aws_iam_policy.gha_backend_ecr.arn]
}

# ---- GenAI 팀 CI (ECR push, main 브랜치만 허용) ----
resource "aws_iam_policy" "gha_genai_ecr" {
  name = "jangin-gha-genai-ecr-push"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Effect = "Allow"
        Action = ["ecr:BatchCheckLayerAvailability", "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload"]
        Resource = [
          "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/jangin-ai/sglang",
          "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/jangin-ai/ollama",
        ]
      }
    ]
  })
}

module "github_oidc_genai" {
  source = "../../modules/github_oidc"

  github_org      = "Jangingmall"
  github_repo     = "GenAI"
  github_subjects = ["ref:refs/heads/*"]
  name_suffix     = "ci"

  policy_arns = [aws_iam_policy.gha_genai_ecr.arn]
}

output "github_actions_role_arn_backend" { value = module.github_oidc_backend.role_arn }
output "github_actions_role_arn_genai"   { value = module.github_oidc_genai.role_arn }