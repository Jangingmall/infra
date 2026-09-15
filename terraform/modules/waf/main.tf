# [WAF] ALB(REGIONAL) 앞단 WebACL - AWS Managed Rules 사용
#
# 배포 절차 (네트워크·계정 설계서: "Count → Block 순차 적용"):
#   1) rule_mode = "count"  로 먼저 배포 → 오탐(false positive) 관찰
#   2) 안정화 확인 후 rule_mode = "block" 으로 변수 값만 바꿔 재적용
#
# DAST 스캐너 출발지 IP 허용은 SG 레벨(ALB SG)에서 처리한다 — 이 모듈의 범위 아님.
# staging 검수 종료 후 SG 쪽 룰만 제거하면 되고, 이 WAF 모듈 자체는 손댈 필요 없음.

resource "aws_wafv2_web_acl" "this" {
  name        = var.name
  description = "${var.name} - AWS Managed Rules (${var.rule_mode})"
  scope       = var.scope

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = var.managed_rule_groups
    content {
      name     = rule.value.name
      priority = rule.value.priority

      override_action {
        dynamic "count" {
          for_each = var.rule_mode == "count" ? [1] : []
          content {}
        }
        dynamic "none" {
          for_each = var.rule_mode == "block" ? [1] : []
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = "AWS"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value.name
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = var.name
    sampled_requests_enabled   = true
  }
}
