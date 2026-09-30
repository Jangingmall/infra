locals {
  name = "${var.project}-${var.env}-detect-${var.name_suffix}"
}

data "aws_caller_identity" "current" {}

# ------------------------------------------------------------
# SNS 토픽
#   EventBridge 타깃은 규칙과 같은 리전에 있어야 한다. 그래서 리전마다
#   토픽을 하나씩 만든다(전역 서비스 이벤트는 us-east-1 에만 들어온다).
#   암호화는 SNS 관리 키를 쓴다. 앱 CMK 를 쓰면 키 정책에 events/sns 를
#   추가해야 하고 이번 일정에 얻는 것이 없다.
# ------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name              = local.name
  kms_master_key_id = "alias/aws/sns"

  tags = merge(var.tags, {
    Name = local.name
  })
}

# EventBridge 가 이 토픽에 publish 할 수 있게 한다.
# SourceAccount 조건으로 다른 계정의 EventBridge 는 막는다.
data "aws_iam_policy_document" "topic" {
  statement {
    sid     = "AllowEventBridgePublish"
    effect  = "Allow"
    actions = ["sns:Publish"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    resources = [aws_sns_topic.alerts.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.topic.json
}

# 🔴 apply 후 수신자가 확인 메일의 링크를 눌러야 실제로 전달된다.
#    Terraform 은 PendingConfirmation 상태로 만들고 끝낸다.
resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alert_emails)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# ------------------------------------------------------------
# EventBridge 규칙
#   CloudTrail 을 EventBridge 에 "연결"하는 리소스는 없다.
#   API 호출은 기본 버스에 자동으로 들어오고, 우리는 규칙만 만든다.
# ------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "this" {
  for_each = var.rules

  name          = "${local.name}-${each.key}"
  description   = each.value.description
  event_pattern = each.value.event_pattern

  tags = merge(var.tags, {
    Name = "${local.name}-${each.key}"
  })
}

resource "aws_cloudwatch_event_target" "sns" {
  for_each = var.rules

  rule      = aws_cloudwatch_event_rule.this[each.key].name
  target_id = "sns"
  arn       = aws_sns_topic.alerts.arn

  # 🔴 input_transformer 를 쓰지 않는다.
  #    메일을 읽기 좋게 다듬으려면 $.detail.errorCode 같은 값을 뽑아야 하는데
  #    그 필드는 "실패한 호출"에만 있다. 입력 변환에서 참조한 경로가 이벤트에
  #    없으면 변환이 실패하고 타깃이 호출되지 않을 수 있다.
  #    = 성공한 호출(=대부분의 보안 이벤트)이 조용히 안 오게 된다.
  #
  #    알림이 안 오는 것이 이 구성에서 가장 나쁜 실패다. 본문이 길어지는 것은
  #    받아들이고 원본 이벤트를 그대로 보낸다. 포렌식에도 전체 이벤트가 낫다.
}
