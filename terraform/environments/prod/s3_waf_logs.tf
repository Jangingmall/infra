# [aws-waf-logs] aws-waf-logs-{env}-jangin - WAF 로그 전용, 비공개
# ⚠️ "aws-waf-logs-" 프리픽스는 AWS 하드 제약 — 다른 접두사로 바꾸면 로깅이 멈춘다.

locals {
  waf_logs_bucket_name = "aws-waf-logs-${var.env}-${var.project}"
}

# WAF 로깅도 IRSA가 아니라 delivery.logs.amazonaws.com이 직접 PutObject 한다
data "aws_iam_policy_document" "waf_logs_delivery" {
  statement {
    sid    = "AWSLogDeliveryAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.waf_logs_bucket_name}"]

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

  statement {
    sid    = "AWSLogDeliveryWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions = ["s3:PutObject"]
    # AWS 문서 경로 규칙: {bucket}/AWSLogs/{account_id}/*
    resources = ["arn:aws:s3:::${local.waf_logs_bucket_name}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

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

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

module "s3_waf_logs" {
  source = "../../modules/s3"

  bucket_name = local.waf_logs_bucket_name
  kms_key_arn = module.kms_app.key_arn

  logging_target_bucket  = module.s3_access.bucket_id
  additional_policy_json = data.aws_iam_policy_document.waf_logs_delivery.json

  lifecycle_rules = [
    {
      id              = "waf-logs-expire"
      expiration_days = 30
    },
  ]
}

resource "aws_s3_bucket_policy" "waf_logs" {
  bucket = module.s3_waf_logs.bucket_id
  policy = module.s3_waf_logs.policy_json

  depends_on = [module.s3_waf_logs]
}
