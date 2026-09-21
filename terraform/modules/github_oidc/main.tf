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
        # 🔴 2026-07-15부터 GitHub는 신규/개명/이전된 레포에 sub를
        # "repo:org@ownerID/repo@repoID:subject" 형식(불변 ID 포함)으로 발급한다.
        # 그 이전에 만들어진 레포는 예전 이름 형식 그대로다.
        # 저희 레포는 전부 2026-09 생성이라 신형식 대상이라, 구형+신형 둘 다 매칭 리스트에
        # 넣는다(OR 매칭이라 안전). ID를 모르면(null) 신형식은 생략한다.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = concat(
            [for s in var.github_subjects : "repo:${var.github_org}/${var.github_repo}:${s}"],
            var.github_org_id != null && var.github_repo_id != null ? [
              for s in var.github_subjects : "repo:${var.github_org}@${var.github_org_id}/${var.github_repo}@${var.github_repo_id}:${s}"
            ] : []
          )
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # repository_id/repository_owner_id는 sub와 별개의 클레임(AWS가 2026-01부터
        # trust policy 조건 키로 지원). IfExists라 클레임이 없어도 인증 자체는 막지 않는다.
        StringEqualsIfExists = merge(
          var.github_org_id != null ? { "token.actions.githubusercontent.com:repository_owner_id" = var.github_org_id } : {},
          var.github_repo_id != null ? { "token.actions.githubusercontent.com:repository_id" = var.github_repo_id } : {},
        )
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "this" {
  for_each   = toset(var.policy_arns)
  role       = aws_iam_role.this.name
  policy_arn = each.value
}