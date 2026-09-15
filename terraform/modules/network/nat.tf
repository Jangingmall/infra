# ============================================================
# nat.tf — NAT Gateway + 고정 EIP (IaC ⑤)   💰 유료
# ------------------------------------------------------------
# 무엇을 하는 물건인가 (쉽게):
#   app 서브넷의 노드·Pod 는 공인 IP 가 없어서 인터넷으로 나갈 수 없다.
#   NAT Gateway 는 "대표 전화" 역할을 한다 —
#   나갈 때는 NAT 의 공인 IP 로 바꿔서 나가고, 답장은 NAT 가 받아서 원래 Pod 에 돌려준다.
#   밖에서 먼저 거는 전화(인바운드)는 받지 않는다. 그래서 단방향이다.
#
#   이 경로로 나가는 것: ECR · STS · EC2 API · 토스페이먼츠 · 카카오/구글/네이버 OAuth ·
#                        스마트택배 · Google SMTP(587/465)
#   이 경로로 안 나가는 것: S3 — ④ Gateway Endpoint 가 더 짧은 경로라 그쪽이 이긴다(무료).
#
# 💰 요금: 시간당 요금 + 처리 데이터(GB)당 요금. 하루 9시간이 아니라 24시간 과금된다.
#    작업 규칙 17 — 9/17 까지 plan 까지만, apply 는 9/18 일괄.
# ============================================================


# ------------------------------------------------------------
# 고정 공인 IP (EIP)
# ------------------------------------------------------------
# 🔴 이 리소스는 NAT Gateway 와 "생명주기를 일부러 분리"했다.
#
#    이유: 스마트택배가 우리 서버의 출발지 IP 를 allowlist 에 등록한다.
#    이 IP 가 바뀌면 배송조회가 그날로 끊긴다 (작업 규칙 12).
#
#    NAT Gateway 는 비용 절감을 위해 내렸다 올릴 수 있어야 하지만(10/1~10/4 노드 내리기),
#    EIP 는 그때도 살아 있어야 같은 IP 로 다시 붙는다.
#    → NAT 에는 count 를 걸고, EIP 에는 걸지 않는다.
#
# ⚠️ EIP 는 NAT 에 붙어 있지 않아도 공인 IPv4 요금이 계속 나간다.
#    (비용 산정서의 "공인 IPv4 3개" 항목에 이미 포함돼 있다)
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${local.name}-eip-nat"
  }

  lifecycle {
    # 🔴 실수로 destroy 되는 것을 Terraform 단에서 차단한다.
    #    이 블록이 있으면 terraform destroy 자체가 실패한다.
    #    정말 지워야 할 때는 이 줄을 먼저 코드에서 지우고 PR 을 올린다
    #    — "지우려면 리뷰를 거쳐라" 가 이 장치의 목적이다.
    prevent_destroy = true
  }
}


# ------------------------------------------------------------
# NAT Gateway
# ------------------------------------------------------------
resource "aws_nat_gateway" "main" {
  # 비용 절감 스위치. 10/1~10/4 처럼 환경을 내릴 때 false 로 바꾸면
  # NAT 만 사라지고 EIP 는 남는다 → 다시 올려도 같은 IP.
  count = var.enable_nat_gateway ? 1 : 0

  allocation_id     = aws_eip.nat.id
  connectivity_type = "public"

  # 🔴 NAT 는 "public 서브넷"에 둬야 한다.
  #    NAT 자신이 IGW 로 나갈 수 있어야 하기 때문이다.
  #    app 서브넷에 두면 자기도 못 나가서 아무 의미가 없다.
  #    초보가 가장 많이 틀리는 지점이다.
  subnet_id = aws_subnet.public[var.nat_gateway_az].id

  tags = {
    Name = "${local.name}-nat-${var.nat_gateway_az}"
  }

  # ⚠️ 이 프로젝트에서 depends_on 을 쓰는 유일한 자리다.
  #    평소엔 "참조가 곧 순서"라 depends_on 이 필요 없지만,
  #    NAT 는 IGW 를 코드에서 참조하지 않으면서도 IGW 가 먼저 있어야 동작한다
  #    (표현할 수 없는 의존성). HashiCorp 공식 문서도 이 경우를 명시한다.
  depends_on = [aws_internet_gateway.main]

  lifecycle {
    precondition {
      # nat_gateway_az 로 준 값이 실제로 만든 AZ 목록에 있는지 apply 전에 검증한다.
      # 없으면 aws_subnet.public["x"] 에서 알아보기 힘든 에러가 난다.
      condition     = contains(var.az_suffixes, var.nat_gateway_az)
      error_message = "nat_gateway_az 는 az_suffixes 안에 있는 값이어야 합니다. (예: az_suffixes = [\"a\", \"c\"] 이면 \"a\" 또는 \"c\")"
    }
  }
}


# ------------------------------------------------------------
# app 라우팅 테이블 → NAT 경로
# ------------------------------------------------------------
# 이 한 줄이 추가되어야 app 서브넷이 비로소 인터넷으로 나갈 수 있다.
#
# 🔴 data 라우팅 테이블에는 이 경로를 절대 만들지 않는다 (작업 규칙 7 · 보안팀 NAT 조건 #2).
#    보안팀 검증도 간단하다 — rt-data 에 0.0.0.0/0 이 있는지만 보면 된다.
resource "aws_route" "app_nat" {
  count = var.enable_nat_gateway ? 1 : 0

  route_table_id         = aws_route_table.app.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[0].id
}


# ------------------------------------------------------------
# CloudWatch 알람 2종 — 보안팀 NAT 승인 조건 #3
# ------------------------------------------------------------
# 보안팀 조건 원문: "모니터링 지표 — ErrorPortAllocation · PacketsDropCount 필수"
#
# 왜 이 두 개인가:
#   ErrorPortAllocation — NAT 가 포트를 더 못 배정한 횟수.
#     NAT 는 하나의 공인 IP 뒤에 수많은 연결을 포트 번호로 구분해 밀어넣는다.
#     포트가 동나면 "인터넷이 갑자기 안 되는" 증상이 나는데,
#     이 지표를 안 보면 원인을 찾는 데 몇 시간이 걸린다.
#   PacketsDropCount — NAT 가 버린 패킷 수. 위 상황의 결과로 나타난다.
#
# 💰 알람 1개당 약 $0.10/월. 2개 = 약 $0.20 — 비용 산정서 미반영이나 무시 가능 수준.
# 🟡 알림 수신처(SNS)는 아직 Terraform 으로 관리하지 않는다.
#    Budget 알림용 SNS 를 재사용할지 새로 만들지 파트장·다정님 확인 필요.
#    확정 전까지 alarm_actions 를 비워 두면 "지표는 쌓이고 알람 상태는 보이되
#    알림만 안 가는" 상태가 된다 — 검수 자료로는 충분하다.
resource "aws_cloudwatch_metric_alarm" "nat_error_port_allocation" {
  count = var.enable_nat_gateway ? 1 : 0

  alarm_name        = "${local.name}-nat-error-port-allocation"
  alarm_description = "NAT Gateway 포트 고갈. 값이 0보다 크면 아웃바운드 연결이 실패하고 있다."

  namespace   = "AWS/NATGateway"
  metric_name = "ErrorPortAllocation"
  statistic   = "Sum"
  period      = 300 # 5분
  dimensions = {
    NatGatewayId = aws_nat_gateway.main[0].id
  }

  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching" # 지표가 안 올라오는 건 정상(=포트 고갈 없음)

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = {
    Name = "${local.name}-nat-error-port-allocation"
  }
}

resource "aws_cloudwatch_metric_alarm" "nat_packets_drop_count" {
  count = var.enable_nat_gateway ? 1 : 0

  alarm_name        = "${local.name}-nat-packets-drop-count"
  alarm_description = "NAT Gateway 패킷 드롭. 지속되면 NAT 이상 또는 포트 고갈을 의심한다."

  namespace   = "AWS/NATGateway"
  metric_name = "PacketsDropCount"
  statistic   = "Sum"
  period      = 300
  dimensions = {
    NatGatewayId = aws_nat_gateway.main[0].id
  }

  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = {
    Name = "${local.name}-nat-packets-drop-count"
  }
}
