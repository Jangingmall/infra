# [s3-cf-logs] jangin-{env}-s3-cf-logs - CloudFront 요청 로그 전용, 비공개, SSE-KMS
# v1(distribution 의 logging_config)은 버킷 ACL 이 필요해 s3 모듈의 BucketOwnerEnforced 와 충돌 → v2(CloudWatch Logs 전송) 사용
# CloudFront 의 delivery source/destination/delivery 는 us-east-1 에서만 만들 수 있다

locals {
  cf_logs_bucket_name = "${var.project}-${var.env}-s3-cf-logs"

  # 로그 전송 출처 = us-east-1 의 delivery source (CloudFront 는 전역 서비스라 us-east-1 고정)
  cf_logs_source_arn = "arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:delivery-source:*"
}

# CloudFront 로그도 IRSA가 아니라 delivery.logs.amazonaws.com이 직접 PutObject 한다
data "aws_iam_policy_document" "cf_logs_delivery" {
  statement {
    sid    = "AWSLogDeliveryAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.cf_logs_bucket_name}"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.cf_logs_source_arn]
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
    # 기본 경로: {bucket}/AWSLogs/{account_id}/CloudFront/...
    resources = ["arn:aws:s3:::${local.cf_logs_bucket_name}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.cf_logs_source_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

module "s3_cf_logs" {
  source = "../../modules/s3"

  bucket_name = local.cf_logs_bucket_name
  kms_key_arn = module.kms_app.key_arn

  enable_logging         = true
  logging_target_bucket  = module.s3_access.bucket_id
  additional_policy_json = data.aws_iam_policy_document.cf_logs_delivery.json

  # 보관기간 — 다른 로그 버킷(access·waf-logs·logs)과 동일하게 30일
  lifecycle_rules = [
    {
      id              = "cf-logs-expire"
      expiration_days = 30
    },
  ]
}

resource "aws_s3_bucket_policy" "cf_logs" {
  bucket = module.s3_cf_logs.bucket_id
  policy = module.s3_cf_logs.policy_json

  depends_on = [module.s3_cf_logs]
}

# CloudFront(이미지 CDN) → s3-cf-logs 전송 연결 — 전부 us-east-1
resource "aws_cloudwatch_log_delivery_source" "cf_images" {
  provider = aws.us_east_1

  name         = "${local.name}-cf-images"
  log_type     = "ACCESS_LOGS"
  resource_arn = module.cloudfront_images.distribution_arn
}

resource "aws_cloudwatch_log_delivery_destination" "cf_logs" {
  provider = aws.us_east_1

  name          = "${local.name}-cf-logs"
  output_format = "json"

  delivery_destination_configuration {
    # aws_s3_bucket_policy.cf_logs 를 거쳐 참조해 "버킷 정책이 delivery.logs.amazonaws.com 을 먼저 허용한 뒤" 연결한다
    destination_resource_arn = "arn:aws:s3:::${aws_s3_bucket_policy.cf_logs.bucket}"
  }
}

resource "aws_cloudwatch_log_delivery" "cf_images" {
  provider = aws.us_east_1

  delivery_source_name     = aws_cloudwatch_log_delivery_source.cf_images.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.cf_logs.arn
}
