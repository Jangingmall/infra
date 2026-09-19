# [KMS] modules/kms/main.tf - 앱 공용 CMK

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "this" {
  statement {
    sid    = "EnableIAMUserPermissions"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = length(var.key_user_role_arns) > 0 ? [1] : []
    content {
      sid    = "AllowKeyUsageByAppRoles"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = var.key_user_role_arns
      }

      actions = [
        "kms:Decrypt",
        "kms:Encrypt",
        "kms:GenerateDataKey*",
        "kms:DescribeKey",
      ]

      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = length(var.log_delivery_service_principals) > 0 ? [1] : []
    content {
      sid    = "AllowAWSLogDeliveryService"
      effect = "Allow"

      principals {
        type        = "Service"
        identifiers = var.log_delivery_service_principals
      }

      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey",
      ]

      resources = ["*"]

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }

      condition {
        test     = "ArnLike"
        variable = "aws:SourceArn"
        values   = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"]
      }
    }
  }
}

resource "aws_kms_key" "this" {
  description             = var.description
  deletion_window_in_days = var.deletion_window_in_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.this.json
  tags                    = var.tags
}

resource "aws_kms_alias" "this" {
  name          = var.alias_name
  target_key_id = aws_kms_key.this.key_id
}
