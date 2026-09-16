# ============================================================
# modules/nat/outputs.tf
# ------------------------------------------------------------
# 🔴 모듈 간 연결 원칙: "A 의 output → B 의 variable" 로만 값을 전달한다.
#    다른 모듈이 modules/nat 안의 리소스를 직접 참조하지 않게 한다.
# ============================================================

output "public_ip" {
  description = <<-EOT
    🔑 NAT Gateway 의 고정 공인 IP.
    **스마트택배 allowlist 에 등록할 값**이며, 이 IP 가 바뀌면 배송조회가 끊긴다.
    BE(박다정님 경유)에 전달해야 하는 인계 항목이다.

    ⚠️ enabled = false 여도 값이 나온다. EIP 는 NAT 와 따로 살아 있기 때문이다.
  EOT
  value       = aws_eip.nat.public_ip
}

output "eip_allocation_id" {
  description = "EIP 할당 ID. NAT 를 내렸다 올려도 이 ID 로 같은 IP 가 다시 붙는다."
  value       = aws_eip.nat.allocation_id
}

output "nat_gateway_id" {
  description = "NAT Gateway ID. enabled = false 면 null."
  value       = try(aws_nat_gateway.main[0].id, null)
}

output "az_suffix" {
  description = <<-EOT
    NAT 가 위치한 AZ 접미사. enabled = false 면 null.
    🔴 이 AZ 장애 시 아웃바운드 전체 중단 (보안팀 NAT 조건 #5 — 문서화 대상)
  EOT
  value       = var.enabled ? var.az_suffix : null
}

output "app_route_id" {
  description = "app 라우팅 테이블에 추가된 0.0.0.0/0 경로 ID. 보안팀 검증 자료용."
  value       = try(aws_route.app_nat[0].id, null)
}

output "alarm_names" {
  description = "생성된 CloudWatch 알람 이름 목록 (보안팀 NAT 조건 #3 증빙용)"
  value = compact([
    try(aws_cloudwatch_metric_alarm.nat_error_port_allocation[0].alarm_name, ""),
    try(aws_cloudwatch_metric_alarm.nat_packets_drop_count[0].alarm_name, ""),
  ])
}
