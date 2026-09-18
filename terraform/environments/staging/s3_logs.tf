# [s3-logs] jangin-{env}-s3-logs - vpc-flow/loki/tempo prefix 3종, 비공개, SSE-KMS(CMK)

locals {
  logs_bucket_name = "${var.project}-${var.env}-s3-logs"
}

# VPC Flow Logs는 IRSA Role이 아니라 delivery.logs.amazonaws.com 서비스가 직접 PutObject 하므로
# IAM 정책이 아니라 이 버킷 정책에서 허용해야 함 (kms_app의 log_delivery_service_principals는 KMS 키 사용만 허용, S3 쓰기 권한은 별개)
data "aws_iam_policy_document" "logs_delivery" {
  statement {
    sid    = "AWSLogDeliveryAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl"]
    resources = ["arn:aws:s3:::${local.logs_bucket_name}"]

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
    # vpc-flow/ 를 optional_folder 로 쓰는 AWS 문서 경로 규칙:
    # {bucket}/{optional_folder}/AWSLogs/{account_id}/*
    resources = ["arn:aws:s3:::${local.logs_bucket_name}/vpc-flow/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

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

module "s3_logs" {
  source = "../../modules/s3"

  bucket_name = local.logs_bucket_name
  kms_key_arn = module.kms_app.key_arn

  logging_target_bucket  = module.s3_access.bucket_id
  additional_policy_json = data.aws_iam_policy_document.logs_delivery.json

  lifecycle_rules = [
    {
      id              = "vpc-flow-expire"
      prefix          = "vpc-flow/"
      expiration_days = 30
    },
    {
      id              = "loki-expire"
      prefix          = "loki/"
      expiration_days = 30
    },
    {
      # tempo 자체 기본 보관은 14일이지만, 다른 prefix와 맞춰 30일로 둔다
      id              = "tempo-expire"
      prefix          = "tempo/"
      expiration_days = 30
    },
  ]
}

resource "aws_s3_bucket_policy" "logs" {
  bucket = module.s3_logs.bucket_id
  policy = module.s3_logs.policy_json

  depends_on = [module.s3_logs]
}
