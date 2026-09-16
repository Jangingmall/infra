# ============================================================
# nat.tf — modules/nat 호출 (IaC ⑤)   💰 유료
# ------------------------------------------------------------
# 🔴 작업 규칙 17: 과금 리소스는 9/17 까지 plan 까지만,
#    apply 는 9/18 일괄(파트장 지시). 이 파일이 만드는 것은 전부 과금 대상이다.
#
# 🔄 2026-09-16 신설 (PR #19 파트장 리뷰 반영)
#    기존에는 vpc.tf 안에서 modules/network 에 NAT 인자를 같이 넘겼다.
#    "엔드포인트 일관성" 지적에 따라 modules/nat 로 분리하고 호출 파일도 나눴다.
#
#    🔑 부수 효과: network(무료) / nat(유료) 가 파일 단위로 갈라져
#       "지금 apply 하면 돈이 나가는가"를 파일 이름만 보고 알 수 있게 됐다.
#
# ⚠️ terraform.tfvars 는 한 글자도 바뀌지 않는다.
#    루트 변수명(nat_enabled · nat_gateway_az · nat_alarm_sns_topic_arns)이
#    이미 nat_ 접두사를 쓰고 있었기 때문이다. (B안 컨벤션)
# ============================================================

module "nat" {
  source = "../../modules/nat"

  project = var.project
  env     = var.env

  # ↓ 왼쪽(모듈 내부)은 접두사 없음 / 오른쪽(루트)은 nat_ 접두사
  enabled              = var.nat_enabled
  az_suffix            = var.nat_gateway_az
  alarm_sns_topic_arns = var.nat_alarm_sns_topic_arns

  # ── modules/network 에서 받아오는 값 ──────────────────────
  # 이 세 줄의 참조가 곧 실행 순서다.
  # depends_on 을 쓰지 않아도 Terraform 이 "network 먼저"를 스스로 안다.

  # NAT 를 둘 Public 서브넷. map 을 통째로 넘기고 모듈 안에서 az_suffix 로 찾는다.
  # (루트에서 [...] 로 직접 찾으면 오타 시 "Invalid index" 라는 불친절한 에러가 난다)
  public_subnet_ids_by_az = module.network.public_subnet_ids_by_az

  # 🔴 app 라우팅 테이블만 넘긴다. data 는 절대 넘기지 않는다
  #    (작업 규칙 7 · 보안팀 NAT 조건 #2 — Data 계층 인터넷 직접 접근 금지).
  app_route_table_id = module.network.app_route_table_id

  # 🔑 값을 쓰기 위해서가 아니라 "IGW 가 먼저 생기게" 하려고 넘긴다.
  #    NAT 는 IGW 가 있어야 동작하는데 코드상 IGW 를 참조할 일이 없어서,
  #    모듈 안 precondition 이 이 값을 읽게 해 순서를 만든다.
  #    자세한 설명은 modules/nat/main.tf 의 precondition 주석 참조.
  internet_gateway_id = module.network.internet_gateway_id
}
