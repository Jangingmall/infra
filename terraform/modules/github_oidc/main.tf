# ============================================================
# main.tf — GitHub Actions OIDC 인증용 IAM Role
# ------------------------------------------------------------
# OIDC Provider 자체는 scripts/bootstrap-github-oidc.sh로
# 계정당 1회만 미리 생성해둔 것을 전제로 합니다
# (계정 전체에서 1개만 존재 가능한 리소스라 Terraform 밖에서 관리).
# 이 모듈은 그 Provider를 조회만 하고, Role만 생성·관리합니다.
# ⚠️ 이 OIDC Provider는 module.eks가 만드는 EKS OIDC Provider(IRSA용)와
#    별개 리소스입니다. 전자는 "GitHub Actions → AWS" 인증,
#    후자는 "K8s Pod → AWS" 인증(IRSA)으로 목적이 다릅니다.
# ============================================================

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "this" {
  name = "jangin-gha-${lower(var.github_repo)}-${var.name_suffix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            for s in var.github_subjects : "repo:${var.github_org}/${var.github_repo}:${s}"
          ]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "this" {
  for_each   = toset(var.policy_arns)
  role       = aws_iam_role.this.name
  policy_arn = each.value
}