# ============================================================
# outputs.tf — 이 환경이 밖으로 내보내는 값
# ------------------------------------------------------------
# 🔄 2026-09-15 모듈 이관: 리소스를 직접 참조하던 것을
#    module.<이름>.<output> 참조로 바꿨다.
#    output 이름은 그대로 유지한다 — 이름을 바꾸면 이 값을 쓰는
#    타 직군 문서·스크립트가 조용히 깨진다.
#
# 용도:
#   1. terraform output 으로 리소스 ID 를 확인 (인계 문서 재료)
#   2. ⑤~⑩ 단계에서 값 확인
#   3. 보안팀 검증 (rt-data 에 0.0.0.0/0 이 없는지 등)
# ============================================================

# ------------------------------------------------------------
# VPC
# ------------------------------------------------------------

output "vpc_id" {
  description = "VPC ID"
  value       = module.network.vpc_id
}

output "vpc_cidr_block" {
  description = "VPC CIDR 블록"
  value       = module.network.vpc_cidr_block
}

output "azs" {
  description = "AZ 접미사 → 실제 AZ 이름 map"
  value       = module.network.azs
}

# ------------------------------------------------------------
# 서브넷
# ------------------------------------------------------------

output "public_subnet_ids" {
  description = "Public 서브넷 ID 목록 (ALB 배치용)"
  value       = module.network.public_subnet_ids
}

output "app_subnet_ids" {
  description = "App 서브넷 ID 목록 (/20 · EKS 노드·Pod)"
  value       = module.network.app_subnet_ids
}

output "data_subnet_ids" {
  description = "Data 서브넷 ID 목록 (예약 · 현재 미사용)"
  value       = module.network.data_subnet_ids
}

output "app_subnet_ids_by_az" {
  description = "AZ 접미사 → App 서브넷 ID map (⑤ NAT · ⑦ 노드그룹에서 AZ-a 선택용)"
  value       = module.network.app_subnet_ids_by_az
}

output "public_subnet_ids_by_az" {
  description = "AZ 접미사 → Public 서브넷 ID map (⑤ NAT Gateway 배치용)"
  value       = module.network.public_subnet_ids_by_az
}

# ------------------------------------------------------------
# 라우팅
# ------------------------------------------------------------

output "public_route_table_id" {
  description = "Public 라우팅 테이블 ID"
  value       = module.network.public_route_table_id
}

output "app_route_table_id" {
  description = "App 라우팅 테이블 ID (⑤ NAT 경로가 붙을 곳)"
  value       = module.network.app_route_table_id
}

output "data_route_table_id" {
  description = <<-EOT
    Data 라우팅 테이블 ID.
    🔴 보안팀 검증 포인트 — 여기에 0.0.0.0/0 이 없어야 한다.
       확인: aws ec2 describe-route-tables --route-table-ids <이 값> \
             --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`]'
       기대 출력: []
  EOT
  value       = module.network.data_route_table_id
}

# ------------------------------------------------------------
# Security Group
# ------------------------------------------------------------

output "sg_alb_id" {
  description = "sg-alb ID"
  value       = module.security.alb_id
}

output "sg_eks_node_id" {
  description = "sg-eks-node ID (⑦ 노드그룹에서 사용)"
  value       = module.security.eks_node_id
}

output "sg_db_id" {
  description = "sg-db ID"
  value       = module.security.db_id
}

output "sg_eks_gpu_id" {
  description = "sg-eks-gpu ID"
  value       = module.security.eks_gpu_id
}

output "security_group_ids" {
  description = "SG 이름 → ID map (인계 문서용 한눈 보기)"
  value       = module.security.security_group_ids
}

output "default_security_group_id" {
  description = "규칙 0개로 잠근 기본 SG ID"
  value       = module.network.default_security_group_id
}

# ------------------------------------------------------------
# VPC Endpoint
# ------------------------------------------------------------

output "s3_vpc_endpoint_id" {
  description = "S3 Gateway Endpoint ID"
  value       = module.endpoints.s3_endpoint_id
}

output "s3_prefix_list_id" {
  description = "S3 관리형 prefix list ID (pl-xxxx) — SG 규칙·라우팅에서 공통 사용"
  value       = module.security.s3_prefix_list_id
}

# ------------------------------------------------------------
# ⑤ NAT Gateway
# ------------------------------------------------------------

output "nat_public_ip" {
  description = <<-EOT
    🔑 NAT Gateway 고정 공인 IP — **스마트택배 allowlist 등록 대상**.
    이 값이 바뀌면 배송조회가 끊기므로 EIP 에 prevent_destroy 를 걸어 두었다.
    확인: terraform output nat_public_ip
  EOT
  value       = module.nat.public_ip
}

output "nat_eip_allocation_id" {
  description = "EIP 할당 ID. NAT 를 내렸다 올려도 이 ID 로 같은 IP 가 다시 붙는다."
  value       = module.nat.eip_allocation_id
}

output "nat_gateway_id" {
  description = "NAT Gateway ID (nat_enabled = false 면 null)"
  value       = module.nat.nat_gateway_id
}

output "nat_gateway_az" {
  description = <<-EOT
    NAT 가 위치한 AZ 접미사. 🔴 이 AZ 장애 시 아웃바운드 전체 중단
    (보안팀 NAT 승인 조건 #5 — 잔여 리스크로 문서화)
  EOT
  value       = module.nat.az_suffix
}

output "nat_alarm_names" {
  description = "NAT CloudWatch 알람 이름 목록 (보안팀 NAT 승인 조건 #3 증빙용)"
  value       = module.nat.alarm_names
}
