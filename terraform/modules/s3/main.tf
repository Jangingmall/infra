# [S3] 범용 S3 버킷 모듈
#
# 버킷마다 다른 것은 전부 변수로 받음 (암호화 방식, 버전관리, lifecycle, CORS)

resource "aws_s3_bucket" "this" {
  bucket = var.bucket_name

  tags = merge(
    var.tags,
    { Name = var.bucket_name }
  )
}

# (images의 products/* 공개는 CloudFront OAC가 담당하며, 이 설정을 우회하지 않는다)
resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Object Ownership — ACL 비활성화
resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# 서버측 암호화
# kms_key_arn 이 있으면 SSE-KMS(CMK), 없으면 SSE-S3(AES256)
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }

    bucket_key_enabled = var.kms_key_arn != null
  }

  # 버킷이 S3 서버 접근 로깅의 대상(is_log_destination = true)이면
  # kms_key_arn은 반드시 null이어야 한다. AWS는 로깅 대상 버킷에
  # SSE-KMS 기본 암호화를 지원하지 않고, 로그가 조용히 전달되지 않는다.
  lifecycle {
    precondition {
      condition     = !(var.is_log_destination && var.kms_key_arn != null)
      error_message = "이 버킷은 is_log_destination = true 로 선언된 S3 서버 접근 로깅의 대상 버킷입니다. AWS는 로깅 대상 버킷의 SSE-KMS 기본 암호화를 지원하지 않습니다(SSE-S3만 허용). kms_key_arn을 null로 두세요."
    }
  }
}

# 버전관리 (선택)
resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = var.versioning_enabled ? "Enabled" : "Disabled"
  }
}

# lifecycle 규칙
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  # versioning 리소스보다 먼저 적용되면 noncurrent_version_expiration 규칙이
  # 의도와 다르게 동작할 수 있어 순서를 명시적으로 강제
  depends_on = [aws_s3_bucket_versioning.this]

  dynamic "rule" {
    for_each = var.lifecycle_rules
    content {
      id     = rule.value.id
      status = "Enabled"

      filter {
        prefix = rule.value.prefix
      }

      dynamic "transition" {
        for_each = rule.value.transition_days == null ? [] : [1]
        content {
          days          = rule.value.transition_days
          storage_class = rule.value.transition_storage_class
        }
      }

      # 만료 삭제
      dynamic "expiration" {
        for_each = rule.value.expiration_days == null ? [] : [1]
        content {
          days = rule.value.expiration_days
        }
      }

      # 구버전 객체 만료 (버전관리 켠 버킷에서만 의미 있음)
      dynamic "noncurrent_version_expiration" {
        for_each = rule.value.noncurrent_version_expiration_days == null ? [] : [1]
        content {
          noncurrent_days = rule.value.noncurrent_version_expiration_days
        }
      }
    }
  }

  # 버킷 전체 대상 - prefix 지정 없이 항상 적용 (lifecycle_rules가 비어 있어도 동작)
  rule {
    id     = "abort-incomplete-multipart-upload"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# CORS (선택) — images / returns 만 사용
resource "aws_s3_bucket_cors_configuration" "this" {
  count = length(var.cors_allowed_origins) > 0 ? 1 : 0

  bucket = aws_s3_bucket.this.id

  cors_rule {
    allowed_origins = var.cors_allowed_origins
    allowed_methods = var.cors_allowed_methods
    allowed_headers = var.cors_allowed_headers
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# 접근 로깅 (선택) → jangin-{env}-s3-access 로 전송
# 대상 버킷 안에서 원본 버킷별로 자동 분리(partitioned prefix)해 로그가 한 버킷 안에서 섞이지 않게 함
resource "aws_s3_bucket_logging" "this" {
  count = var.enable_logging ? 1 : 0

  bucket = aws_s3_bucket.this.id

  target_bucket = var.logging_target_bucket
  target_prefix = var.logging_target_prefix

  target_object_key_format {
    partitioned_prefix {
      partition_date_source = "EventTime"
    }
  }
}

# 버킷 정책 문서 — TLS 강제 + additional_policy_json 병합
data "aws_iam_policy_document" "this" {
  # 1. TLS 강제 — 평문 HTTP 요청 전면 거부
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # 2. 환경에서 넘긴 추가 정책 문서를 병합
  #    (ex. CloudFront OAC 허용, WAF/CloudTrail/VPC Flow Logs 로그 전달 서비스 허용)
  source_policy_documents = var.additional_policy_json == null ? [] : [var.additional_policy_json]
}
