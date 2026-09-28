resource "aws_guardduty_detector" "shared" {
  enable = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_guardduty_detector_feature" "optional_disabled" {
  for_each = toset([
    "S3_DATA_EVENTS",
    "EKS_AUDIT_LOGS",
    "EBS_MALWARE_PROTECTION",
    "RDS_LOGIN_EVENTS",
    "LAMBDA_NETWORK_LOGS",
    "RUNTIME_MONITORING",
  ])

  detector_id = aws_guardduty_detector.shared.id
  name        = each.value
  status      = "DISABLED"
}

resource "aws_securityhub_account" "shared" {
  enable_default_standards = false
  auto_enable_controls    = false

  lifecycle {
    prevent_destroy = true
  }
}
