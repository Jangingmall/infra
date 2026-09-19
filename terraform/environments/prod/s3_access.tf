# [s3-access] jangin-{env}-s3-access - S3 서버 접근 로그 전용, 비공개, SSE-S3(KMS 금지)

locals {
  access_bucket_name = "${var.project}-${var.env}-s3-access"
}

data "aws_iam_policy_document" "access_delivery" {
  statement {
    sid    = "S3ServerAccessLogsPolicy"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${local.access_bucket_name}/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        "arn:aws:s3:::${var.project}-${var.env}-s3-*",
        "arn:aws:s3:::aws-waf-logs-${var.env}-${var.project}",
      ]
    }
  }
}

module "s3_access" {
  source = "../../modules/s3"

  bucket_name        = local.access_bucket_name
  kms_key_arn        = null
  is_log_destination = true

  additional_policy_json = data.aws_iam_policy_document.access_delivery.json

  lifecycle_rules = [
    {
      id              = "access-expire"
      expiration_days = 30
    },
  ]
}

resource "aws_s3_bucket_policy" "access" {
  bucket = module.s3_access.bucket_id
  policy = module.s3_access.policy_json

  depends_on = [module.s3_access]
}
