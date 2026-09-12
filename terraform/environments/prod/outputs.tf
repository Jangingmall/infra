# ============================================================
# outputs.tf — 다음 단계와 타 직군에 넘길 값
# ------------------------------------------------------------
# 쓰임새 3가지
#   1. 클라우드 네이티브 과정(박명수)이 k8s 워크로드를 올릴 때 필요한
#      서브넷 ID 전달
#   2. Phase3 산출물 #2 "클러스터 환경 인계 문서" 기초 자료
#   3. terraform output 으로 내 눈으로 검증
#
# 참고: 같은 디렉토리(flat) 구성이라 ③ SG · ④ Endpoint 는
#       aws_subnet.app 처럼 리소스를 직접 참조할 수 있다.
#       즉 기능상 필수는 아니고, 위 3가지가 목적이다.
#
# 🔴 계정 ID·ARN·시크릿은 output에 넣지 않는다 (작업 규칙 2).
#    VPC ID·서브넷 ID는 비밀이 아니므로 sensitive 표시가 불필요하다.
# ============================================================

output "vpc_id" {
  description = "VPC ID — ③ SG, ⑥ EKS, 네이티브 과정에서 사용"
  value       = aws_vpc.main.id
}

output "vpc_cidr_block" {
  description = "VPC CIDR — NetworkPolicy·NACL 작성 시 사용"
  value       = aws_vpc.main.cidr_block
}

output "azs" {
  description = "사용 중인 AZ (접미사 => AZ 이름)"
  value       = local.azs
}

# ------------------------------------------------------------
# 서브넷 — { "a" = "subnet-xxx", "c" = "subnet-yyy" } 형태
#
# for_each 로 만들었으므로 결과가 map 이다. map 그대로 내보내면
# 어느 AZ의 서브넷인지가 키에 남아 인계 문서에 그대로 쓸 수 있다.
# 리스트가 필요하면 받는 쪽에서 values(...) 로 뽑는다.
# ------------------------------------------------------------

output "public_subnet_ids" {
  description = "Public 서브넷 ID — ⑩ ALB 배치용"
  value       = { for k, s in aws_subnet.public : k => s.id }
}

output "app_subnet_ids" {
  description = "Private App 서브넷 ID — ⑥ EKS 노드그룹 / 네이티브 워크로드용"
  value       = { for k, s in aws_subnet.app : k => s.id }
}

output "data_subnet_ids" {
  description = "Private Data 서브넷 ID — ⑦ DB 노드그룹용"
  value       = { for k, s in aws_subnet.data : k => s.id }
}

# ------------------------------------------------------------
# 라우팅 테이블 — 다음 단계에서 "여기에 붙여야 하는" 대상
# ------------------------------------------------------------

output "public_route_table_id" {
  description = "Public 라우팅 테이블 ID (IGW 경로 보유)"
  value       = aws_route_table.public.id
}

output "app_route_table_id" {
  description = "App 라우팅 테이블 ID — ⑤ NAT Gateway 경로를 여기에 추가"
  value       = aws_route_table.app.id
}

output "data_route_table_id" {
  description = "Data 라우팅 테이블 ID — ④ S3 Gateway Endpoint 를 여기에 연결 (0.0.0.0/0 없음)"
  value       = aws_route_table.data.id
}
