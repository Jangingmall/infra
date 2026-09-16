# ============================================================
# modules/nat/main.tf — NAT Gateway + 고정 EIP + 알람 (IaC ⑤)   💰 유료
# ------------------------------------------------------------
# 무엇을 하는 물건인가 (쉽게):
#   app 서브넷의 노드·Pod 는 공인 IP 가 없어서 인터넷으로 나갈 수 없다.
#   NAT Gateway 는 "회사 대표 전화" 역할을 한다 —
#   나갈 때는 NAT 의 공인 IP 로 바꿔서 나가고, 답장은 NAT 가 받아서 원래 Pod 에 돌려준다.
#   밖에서 먼저 거는 전화(인바운드)는 받지 않는다. 그래서 단방향이다.
#
#   이 경로로 나가는 것: ECR · STS · EC2 API · 토스페이먼츠 ·
#                        카카오/구글/네이버 OAuth · 스마트택배 · Google SMTP
#   이 경로로 안 나가는 것: S3 — ④ Gateway Endpoint 가 더 짧은 경로라 그쪽이 이긴다(무료).
#
# 🔄 2026-09-16 모듈 분리 (PR #19 파트장 리뷰 반영)
#    기존 modules/network/nat.tf 에 있던 것을 이 모듈로 옮겼다.
#    이유 두 가지:
#      1. 다른 모듈(endpoints·security·eks·ecr·alb)이 전부 "1 모듈 = 1 관심사"인데
#         network 만 VPC + NAT 두 가지를 갖고 있어 일관성이 없었다.
#      2. 🔑 network 는 전부 무료, nat 는 전부 유료다.
#         모듈 경계가 과금 경계와 일치하면 작업 규칙 17
#         ("과금 리소스는 9/18 일괄 apply")이 폴더 구조만 봐도 드러난다.
#
#    ⚠️ moved 블록은 만들지 않는다. moved 는 "이미 배포된" 리소스를 옮길 때만 쓴다
#       (작업 규칙 15). ⑤ 는 아직 apply 한 적이 없어 State 에 없으므로 해당 없음.
#
# 💰 요금: 시간당 요금 + 처리 데이터(GB)당 요금.
#    하루 9시간 운영이어도 NAT 는 24시간 과금된다. 끌 수 없는 상시 비용에 속한다.
# ============================================================


# ------------------------------------------------------------
# 고정 공인 IP (EIP)
# ------------------------------------------------------------
# 🔴 이 리소스만 count 를 걸지 않았다. NAT 와 생명주기를 일부러 분리한 것이다.
#
#    이유: 스마트택배가 우리 서버의 출발지 IP 를 allowlist 에 등록한다.
#    이 IP 가 바뀌면 배송조회가 그날로 끊긴다 (작업 규칙 9).
#
#    NAT Gateway 는 비용 절감을 위해 내렸다 올릴 수 있어야 하지만(10/1~10/4),
#    EIP 는 그때도 살아 있어야 같은 IP 로 다시 붙는다.
#    → NAT 에는 count, EIP 에는 count 없음.
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
    #    — "지우려면 리뷰를 거쳐라" 가 이 장치의 목적이다. (작업 규칙 9)
    prevent_destroy = true
  }
}


# ------------------------------------------------------------
# NAT Gateway
# ------------------------------------------------------------
resource "aws_nat_gateway" "main" {
  # 비용 절감 스위치. false 로 바꾸면 NAT 만 사라지고 EIP 는 남는다.
  count = var.enabled ? 1 : 0

  allocation_id     = aws_eip.nat.id
  connectivity_type = "public"
  subnet_id         = local.nat_subnet_id

  tags = {
    Name = "${local.name}-nat-${var.az_suffix}"
  }

  lifecycle {
    # ── precondition 1: AZ 오타 잡기 ──────────────────────────
    # locals.tf 의 lookup 이 키를 못 찾으면 빈 문자열이 된다.
    # 그대로 두면 AWS 가 "subnet id 형식이 아니다" 같은 엉뚱한 에러를 내므로
    # 여기서 먼저 잡아 사람이 읽을 수 있는 메시지를 낸다.
    precondition {
      condition     = local.nat_subnet_id != ""
      error_message = "az_suffix 는 public_subnet_ids_by_az 의 키여야 합니다. 현재 사용 가능한 값을 확인하세요 (예: a, c)."
    }

    # ── precondition 2: IGW 가 먼저 생기게 만들기 ──────────────
    # 🔑 여기가 이번 모듈 분리에서 가장 신경 쓴 부분이다.
    #
    # [문제]
    #   NAT 는 IGW 가 있어야 인터넷으로 나갈 수 있다. 그런데 NAT 리소스의
    #   어떤 인자도 IGW 를 가리키지 않는다. Terraform 은 "참조가 곧 순서"라
    #   참조가 없으면 순서를 모르고 둘을 동시에 만들려 한다.
    #   HashiCorp 공식 문서도 이 경우를 "표현할 수 없는 의존성"이라 부르며
    #   명시적 처리를 권고한다.
    #
    # [기존 방식]
    #   같은 모듈 안이었으므로 depends_on = [aws_internet_gateway.main] 으로 해결했다.
    #   모듈이 분리되면서 이 리소스 주소를 더 이상 쓸 수 없게 됐다.
    #
    # [택하지 않은 대안]
    #   루트에서 module "nat" { depends_on = [module.network] } 로 걸 수 있다.
    #   하지만 모듈 단위 depends_on 은 nat 모듈의 모든 리소스가 network 모듈의
    #   모든 리소스를 기다리게 만들고, plan 단계에서 출력값이 "known after apply"로
    #   번지는 부작용이 있다. 필요한 건 "NAT 하나가 IGW 하나를 기다리는 것"뿐이다.
    #
    # [택한 방식]
    #   precondition 이 var.internet_gateway_id 를 읽게 한다.
    #   이 값은 루트에서 module.network.internet_gateway_id 로 연결되어 있고
    #   plan 시점에는 "아직 모름" 상태다. Terraform 은 모르는 값으로 검사를 할 수 없으니
    #   IGW 가 실제로 만들어질 때까지 이 리소스를 시작하지 않는다.
    #   → 리소스 하나 단위의 정확한 순서가 생긴다.
    #
    # ⚠️ 검사 내용 자체("빈 값이 아닐 것")는 사실상 항상 참이다.
    #    순서를 만드는 것이 이 블록의 진짜 목적이라는 점을 알고 읽어야 한다.
    precondition {
      condition     = var.internet_gateway_id != ""
      error_message = "internet_gateway_id 가 비어 있습니다. NAT 는 같은 VPC 의 Internet Gateway 가 있어야 동작합니다."
    }
  }
}


# ------------------------------------------------------------
# app 라우팅 테이블 → NAT 경로
# ------------------------------------------------------------
# 이 한 줄이 추가되어야 app 서브넷이 비로소 인터넷으로 나갈 수 있다.
#
# 라우팅 테이블 자체는 modules/network 가 만들고, 그 안의 경로 한 줄만
# 이 모듈이 추가한다. modules/endpoints 가 S3 Gateway Endpoint 를
# 같은 라우팅 테이블에 붙이는 것과 똑같은 패턴이다.
#
# 🔴 data 라우팅 테이블에는 이 경로를 절대 만들지 않는다
#    (작업 규칙 7 · 보안팀 NAT 조건 #2).
#    보안팀 검증도 간단하다 — rt-data 에 0.0.0.0/0 이 있는지만 보면 된다.
resource "aws_route" "app_nat" {
  count = var.enabled ? 1 : 0

  route_table_id         = var.app_route_table_id
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
resource "aws_cloudwatch_metric_alarm" "nat_error_port_allocation" {
  count = var.enabled ? 1 : 0

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
  count = var.enabled ? 1 : 0

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
