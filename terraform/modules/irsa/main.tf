data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.project}-${var.env}-irsa-${var.name}"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = merge(
    {
      Environment = var.env
      Project     = var.project
      ManagedBy   = "Terraform"
      Owner       = "infra"
    },
    var.tags,
  )
}

resource "aws_iam_policy" "custom" {
  count  = var.policy_json != null ? 1 : 0
  name   = "${var.project}-${var.env}-irsa-policy-${var.name}"
  policy = var.policy_json
}

resource "aws_iam_role_policy_attachment" "custom" {
  count      = var.policy_json != null ? 1 : 0
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.custom[0].arn
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each   = toset(var.managed_policy_arns)
  role       = aws_iam_role.this.name
  policy_arn = each.value
}