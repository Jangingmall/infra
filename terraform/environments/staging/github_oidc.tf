# ============================================================
# github_oidc.tf — GitHub Actions OIDC 인증 (staging)
# ------------------------------------------------------------
# 🔴 전제조건: scripts/bootstrap-github-oidc.sh를 먼저 실행해
#    OIDC Provider가 계정에 존재해야 합니다 (계정당 최초 1회만).
#    미실행 상태에서 apply하면 모듈의 data source 조회가 실패합니다.
#
# GitHub 리포지토리 Settings → Environments → "staging"이
# 미리 생성되어 있어야 sub 클레임이 일치합니다.
# ============================================================

module "github_oidc" {
  source = "../../modules/github_oidc"

  github_org      = "Jangingmall"
  github_repo     = "infra"
  github_subjects = ["environment:staging"]
  name_suffix     = "staging"

  policy_arns = [
    "arn:aws:iam::aws:policy/PowerUserAccess",
    "arn:aws:iam::aws:policy/IAMFullAccess",
  ]
}

output "github_actions_role_arn" { value = module.github_oidc.role_arn }