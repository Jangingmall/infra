# ============================================================
# moved.tf — 모듈 이관용 주소 변경 선언 (2026-09-15)
# ------------------------------------------------------------
# 🔴 이 파일이 없으면 배포된 43개 리소스가 전부 destroy + create 됩니다.
#
# 왜 그런가 (쉽게):
#   Terraform 은 리소스를 "주소"로 기억합니다.
#   지금 VPC 의 주소는 aws_vpc.main 인데, 코드를 modules/network 로
#   옮기면 주소가 module.network.aws_vpc.main 으로 바뀝니다.
#   Terraform 입장에서는 "원래 주소의 물건이 사라졌고,
#   처음 보는 주소에 새 물건이 생겼다" 로 읽힙니다 → 철거 후 신축.
#   VPC 가 철거되면 그 안의 서브넷·SG·엔드포인트가 전부 딸려 나갑니다.
#
#   moved 블록은 "철거가 아니라 이사다" 라고 알려주는 전입신고서입니다.
#   State 파일 안의 주소만 갈아끼우고 실제 AWS 리소스는 건드리지 않습니다.
#
# 왜 terraform state mv (CLI) 를 쓰지 않는가:
#   CLI 로 하면 코드에 흔적이 남지 않아서, 다른 팀원이 pull 받고
#   plan 을 돌리면 그 사람 화면에서는 다시 destroy 가 뜹니다.
#   moved 블록은 코드에 남으므로 팀 전체가 같은 결과를 봅니다. (작업 규칙 15)
#
# for_each 리소스는 어떻게 되는가:
#   aws_subnet.app["a"], ["c"] 처럼 인스턴스가 여러 개여도
#   리소스 단위(aws_subnet.app)로 한 번만 적으면 인스턴스 전체가 함께 이동합니다.
#   인덱스 키가 바뀌지 않기 때문입니다.
#
# 검증 기준:
#   terraform plan → Plan: 0 to add, 0 to change, 0 to destroy.
#   + "... has moved to ..." 목록만 출력되어야 합니다.
#   destroy 가 1개라도 있으면 즉시 중단하고 누락된 moved 를 찾습니다. (작업 규칙 16)
#
# 이 파일의 수명:
#   모든 팀원이 pull 받고 한 번씩 apply 한 뒤에는 지워도 됩니다.
#   다만 프로젝트 기간이 짧으므로 10/2 제출 때까지 그대로 둡니다.
# ============================================================

# ------------------------------------------------------------
# ② network 모듈 — 13블록
# ------------------------------------------------------------

moved {
  from = aws_vpc.main
  to   = module.network.aws_vpc.main
}

moved {
  from = aws_internet_gateway.main
  to   = module.network.aws_internet_gateway.main
}

moved {
  from = aws_subnet.public # for_each: ["a"], ["c"]
  to   = module.network.aws_subnet.public
}

moved {
  from = aws_subnet.app # for_each: ["a"], ["c"]  🔴 /20
  to   = module.network.aws_subnet.app
}

moved {
  from = aws_subnet.data # for_each: ["a"], ["c"]  예약·미사용
  to   = module.network.aws_subnet.data
}

moved {
  from = aws_route_table.public
  to   = module.network.aws_route_table.public
}

moved {
  from = aws_route.public_igw
  to   = module.network.aws_route.public_igw
}

moved {
  from = aws_route_table.app
  to   = module.network.aws_route_table.app
}

moved {
  from = aws_route_table.data # 🔴 0.0.0.0/0 없음 (작업 규칙 7)
  to   = module.network.aws_route_table.data
}

moved {
  from = aws_route_table_association.public
  to   = module.network.aws_route_table_association.public
}

moved {
  from = aws_route_table_association.app
  to   = module.network.aws_route_table_association.app
}

moved {
  from = aws_route_table_association.data
  to   = module.network.aws_route_table_association.data
}

moved {
  from = aws_default_security_group.locked
  to   = module.network.aws_default_security_group.locked
}

# ------------------------------------------------------------
# ③ security 모듈 — 19블록 (SG 4 + ingress 6 + egress 9)
# ------------------------------------------------------------

moved {
  from = aws_security_group.alb
  to   = module.security.aws_security_group.alb
}

moved {
  from = aws_security_group.eks_node
  to   = module.security.aws_security_group.eks_node
}

moved {
  from = aws_security_group.db
  to   = module.security.aws_security_group.db
}

moved {
  from = aws_security_group.eks_gpu
  to   = module.security.aws_security_group.eks_gpu
}

# --- ingress 6 ---

moved {
  from = aws_vpc_security_group_ingress_rule.alb_in_https
  to   = module.security.aws_vpc_security_group_ingress_rule.alb_in_https
}

moved {
  from = aws_vpc_security_group_ingress_rule.alb_in_http
  to   = module.security.aws_vpc_security_group_ingress_rule.alb_in_http
}

moved {
  from = aws_vpc_security_group_ingress_rule.node_in_alb_8080
  to   = module.security.aws_vpc_security_group_ingress_rule.node_in_alb_8080
}

moved {
  from = aws_vpc_security_group_ingress_rule.node_in_self_9090
  to   = module.security.aws_vpc_security_group_ingress_rule.node_in_self_9090
}

moved {
  from = aws_vpc_security_group_ingress_rule.db_in_node_5432
  to   = module.security.aws_vpc_security_group_ingress_rule.db_in_node_5432
}

moved {
  from = aws_vpc_security_group_ingress_rule.gpu_in_node_8000
  to   = module.security.aws_vpc_security_group_ingress_rule.gpu_in_node_8000
}

# --- egress 9 ---

moved {
  from = aws_vpc_security_group_egress_rule.alb_out_node_8080
  to   = module.security.aws_vpc_security_group_egress_rule.alb_out_node_8080
}

moved {
  from = aws_vpc_security_group_egress_rule.node_out_db_5432
  to   = module.security.aws_vpc_security_group_egress_rule.node_out_db_5432
}

moved {
  from = aws_vpc_security_group_egress_rule.node_out_gpu_8000
  to   = module.security.aws_vpc_security_group_egress_rule.node_out_gpu_8000
}

moved {
  from = aws_vpc_security_group_egress_rule.node_out_all
  to   = module.security.aws_vpc_security_group_egress_rule.node_out_all
}

moved {
  from = aws_vpc_security_group_egress_rule.node_out_s3_443
  to   = module.security.aws_vpc_security_group_egress_rule.node_out_s3_443
}

moved {
  from = aws_vpc_security_group_egress_rule.db_out_all
  to   = module.security.aws_vpc_security_group_egress_rule.db_out_all
}

moved {
  from = aws_vpc_security_group_egress_rule.db_out_s3_443
  to   = module.security.aws_vpc_security_group_egress_rule.db_out_s3_443
}

moved {
  from = aws_vpc_security_group_egress_rule.gpu_out_all
  to   = module.security.aws_vpc_security_group_egress_rule.gpu_out_all
}

moved {
  from = aws_vpc_security_group_egress_rule.gpu_out_s3_443
  to   = module.security.aws_vpc_security_group_egress_rule.gpu_out_s3_443
}

# ------------------------------------------------------------
# ④ endpoints 모듈 — 2블록
# ------------------------------------------------------------

moved {
  from = aws_vpc_endpoint.s3
  to   = module.endpoints.aws_vpc_endpoint.s3
}

moved {
  from = aws_vpc_endpoint_route_table_association.s3 # for_each: ["app"], ["data"]
  to   = module.endpoints.aws_vpc_endpoint_route_table_association.s3
}

# ============================================================
# ⚠️ data source 는 moved 블록이 필요 없습니다.
#    data.aws_availability_zones.available 과
#    data.aws_ec2_managed_prefix_list.s3 는 매 실행마다 새로 조회되는
#    "읽기 전용 조회"라, 주소가 바뀌어도 파괴될 물건이 없습니다.
#    plan 의 "to add / to destroy" 집계에도 포함되지 않습니다.
# ============================================================
