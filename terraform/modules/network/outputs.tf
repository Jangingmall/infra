# ============================================================
# modules/network/outputs.tf — 다른 모듈이 이 모듈을 쓰려면 필요한 값
# ------------------------------------------------------------
# 🔴 모듈 간 연결 원칙:
#    모듈 B 가 모듈 A 의 리소스를 참조할 때는 반드시
#    "A 의 output → B 의 variable" 로 전달한다.
#    modules/security 안에서 aws_vpc.main.id 를 직접 쓰면
#    그 모듈은 이 네트워크 모듈 없이는 못 쓰는 물건이 된다.
# ============================================================

output "vpc_id" {
  description = "VPC ID. security / endpoints / eks 모듈이 받아 쓴다."
  value       = aws_vpc.main.id
}

output "vpc_cidr_block" {
  description = "VPC CIDR 블록"
  value       = aws_vpc.main.cidr_block
}

output "azs" {
  description = "AZ 접미사 → 실제 AZ 이름 map. { a = \"ap-northeast-2a\", ... }"
  value       = local.azs
}

output "public_subnet_ids" {
  description = "Public 서브넷 ID 목록 (ALB 배치용)"
  value       = [for s in aws_subnet.public : s.id]
}

output "app_subnet_ids" {
  description = "App 서브넷 ID 목록 (/20 · EKS 노드·Pod 배치용)"
  value       = [for s in aws_subnet.app : s.id]
}

output "data_subnet_ids" {
  description = "Data 서브넷 ID 목록 (예약 · 현재 미사용)"
  value       = [for s in aws_subnet.data : s.id]
}

output "public_subnet_ids_by_az" {
  description = "AZ 접미사 → Public 서브넷 ID map (AZ 지정 배치가 필요할 때)"
  value       = { for k, s in aws_subnet.public : k => s.id }
}

output "app_subnet_ids_by_az" {
  description = "AZ 접미사 → App 서브넷 ID map (⑤ NAT · ⑦ 노드그룹에서 AZ-a 만 골라 쓸 때)"
  value       = { for k, s in aws_subnet.app : k => s.id }
}

output "public_route_table_id" {
  description = "Public 라우팅 테이블 ID"
  value       = aws_route_table.public.id
}

output "app_route_table_id" {
  description = "App 라우팅 테이블 ID (⑤ NAT 경로가 여기 붙는다)"
  value       = aws_route_table.app.id
}

output "data_route_table_id" {
  description = "Data 라우팅 테이블 ID. 🔴 0.0.0.0/0 이 없어야 한다 (작업 규칙 7)"
  value       = aws_route_table.data.id
}

output "route_table_ids_for_s3_endpoint" {
  description = <<-EOT
    S3 Gateway Endpoint 를 붙일 라우팅 테이블 map.
    public 이 없는 것이 의도다 — public 은 IGW 직행이고
    동일 리전 S3행은 IGW 경유라도 무료라 붙일 이유가 없다.
  EOT
  value = {
    app  = aws_route_table.app.id
    data = aws_route_table.data.id
  }
}

output "default_security_group_id" {
  description = "규칙 0개로 잠근 기본 SG. 인계 문서·보안팀 검증용."
  value       = aws_default_security_group.locked.id
}

# ------------------------------------------------------------
# ⑤ NAT Gateway
# ------------------------------------------------------------

output "nat_public_ip" {
  description = <<-EOT
    🔑 NAT Gateway 의 고정 공인 IP.
    **스마트택배 allowlist 에 등록할 값**이며, 이 IP 가 바뀌면 배송조회가 끊긴다.
    BE(박다정님 경유)에 전달해야 하는 인계 항목이다.
  EOT
  value       = aws_eip.nat.public_ip
}

output "nat_eip_allocation_id" {
  description = "EIP 할당 ID. NAT 를 내렸다 올려도 이 ID 로 같은 IP 가 다시 붙는다."
  value       = aws_eip.nat.allocation_id
}

output "nat_gateway_id" {
  description = "NAT Gateway ID. enable_nat_gateway = false 면 null."
  value       = try(aws_nat_gateway.main[0].id, null)
}

output "nat_gateway_az" {
  description = "NAT 가 위치한 AZ. 🔴 이 AZ 장애 시 아웃바운드 전체 중단 (보안팀 조건 #5)"
  value       = var.enable_nat_gateway ? local.azs[var.nat_gateway_az] : null
}
