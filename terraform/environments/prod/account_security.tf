resource "aws_s3_account_public_access_block" "shared" {
  account_id = data.aws_caller_identity.current.account_id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ebs_encryption_by_default" "shared" {
  enabled = true

  lifecycle {
    prevent_destroy = true
  }
}
