# 가정: staging/prod는 같은 AWS 계정과 var.region을 사용한다.
# prod state에서만 관리한다. Config 없는 탐지 결과 수집용이며 보안 표준 점검용이 아니다.
# 적용/비용/종료 절차: ../../THREAT_DETECTION.md
resource "aws_guardduty_detector" "shared" {
  enable = true

  lifecycle {
    prevent_destroy = true
  }
}

# 신규 detector에서 일부 선택 기능이 기본 활성화될 수 있어 명시적으로 끈다.
# EKS_RUNTIME_MONITORING은 RUNTIME_MONITORING과 동시에 선언할 수 없다.
# 아래 이름은 AWS provider 5.x API enum이며 환경별 리소스 식별자가 아니다.
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

# 같은 계정/리전의 GuardDuty findings는 AWS 기본 연동으로 수집한다.
# 표준은 Config 기록에 의존하므로 구독하지 않는다. 기존 표준이 있다면 별도 검토 필요.
resource "aws_securityhub_account" "shared" {
  enable_default_standards = false
  auto_enable_controls    = false

  lifecycle {
    prevent_destroy = true
  }
}
