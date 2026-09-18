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

# 🔴 for_each 가 아니라 count 를 쓰는 이유
#    alb-controller 는 managed_policy_arns 로 aws_iam_policy.alb_controller.arn 을 받는데,
#    이 값은 apply 전에는 알 수 없다 (known after apply).
#    for_each 는 인스턴스 "키"를 plan 시점에 확정해야 하므로 unknown 값을 키로 쓸 수 없고,
#    "Invalid for_each argument" 로 plan 자체가 실패한다.
#    count 는 "개수"만 알면 되는데 리스트 길이는 정적이므로 통과한다.
#    (같은 모듈의 custom 정책도 이미 count 패턴이라 스타일도 맞는다)
resource "aws_iam_role_policy_attachment" "managed" {
  count      = length(var.managed_policy_arns)
  role       = aws_iam_role.this.name
  policy_arn = var.managed_policy_arns[count.index]
}