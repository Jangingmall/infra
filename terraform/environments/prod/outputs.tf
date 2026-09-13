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


# ------------------------------------------------------------
# Security Group — ③ security_group.tf
# ------------------------------------------------------------
# 네이티브 과정(박명수) 인계용이자, ⑥⑦⑩ 단계의 입력값이다.
#
# 여기서 ID를 꺼내 쓰는 곳:
#   sg_alb      → ⑩ ALB. Ingress annotation
#                 alb.ingress.kubernetes.io/security-groups
#   sg_eks_node → ⑦ System·App 노드그룹의 추가 SG
#   sg_db       → ⑦ DB 노드그룹의 추가 SG
#   sg_eks_gpu  → ⑦ GPU-A(g6e)·GPU-B(g4dn) 두 노드그룹이 공용으로 사용
#
# ⚠️ EKS 노드그룹에 이 SG를 붙여도, AWS가 자동 생성하는
#    eks-cluster-sg-* 가 함께 붙는다. 클러스터 내부 통신은 그쪽 담당이다.
#    → 여기 SG에 노드↔노드 전체 허용을 추가하지 말 것 (최소권한 유지).
# ------------------------------------------------------------

output "sg_alb_id" {
  description = "ALB SG — 인터넷 443/80 수신, 8080만 노드로 송신"
  value       = aws_security_group.alb.id
}

output "sg_eks_node_id" {
  description = "EKS 워커 노드 SG — System·App 노드그룹용"
  value       = aws_security_group.eks_node.id
}

output "sg_db_id" {
  description = "CNPG 데이터 계층 SG — 5432 인바운드는 sg-eks-node 에서만"
  value       = aws_security_group.db.id
}

output "sg_eks_gpu_id" {
  description = "GPU 노드 SG — 8000 인바운드만. sg-db 로 가는 경로 없음"
  value       = aws_security_group.eks_gpu.id
}


# ------------------------------------------------------------
# VPC Endpoint — ④ endpoints.tf
# ------------------------------------------------------------
# 💡 이 값이 나중에 중요한 이유:
#    ⑨에서 S3 버킷 정책에 조건 aws:SourceVpce = vpce-xxx 를 걸면
#    "이 VPC의 Endpoint를 통해서만 버킷 접근 허용"이 된다.
#    (자격증명이 유출돼도 우리 VPC 밖에서는 못 쓴다)
#    사이버보안팀이 요구할 가능성이 높은 항목이라 미리 꺼내둔다.
#
# prefix_list_id 는 내보내지 않는다 — security_group.tf 가 이미
# data.aws_ec2_managed_prefix_list.s3 로 같은 값을 쓰고 있어 중복이다.

output "s3_vpc_endpoint_id" {
  description = "S3 Gateway Endpoint ID — rt-app · rt-data 에 연결됨. ⑨ 버킷 정책의 aws:SourceVpce 조건에서 사용"
  value       = aws_vpc_endpoint.s3.id
}
