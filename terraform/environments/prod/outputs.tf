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

# ------------------------------------------------------------
# ⑥ EKS 클러스터
# ------------------------------------------------------------

output "eks_cluster_name" {
  description = "EKS 클러스터 이름"
  value       = module.eks.cluster_name
}

output "eks_cluster_version" {
  description = "실제로 생성된 쿠버네티스 버전"
  value       = module.eks.cluster_version
}

output "eks_cluster_endpoint" {
  description = "컨트롤플레인 API 주소"
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_security_group_id" {
  description = <<-EOT
    🔑 EKS 자동 생성 클러스터 SG (eks-cluster-sg-<이름>).
    3-tier 방어 논리의 근거 — 같은 클러스터 노드끼리는 이 SG 로 이미 열려 있으므로
    계층 격리는 서브넷이 아니라 노드그룹·Taint·SG·NetworkPolicy 축으로 이뤄집니다.
  EOT
  value       = module.eks.cluster_security_group_id
}

output "eks_oidc_provider_arn" {
  description = "🔑 ⑧ IRSA 6종의 신뢰 정책에 들어가는 값"
  value       = module.eks.oidc_provider_arn
}

output "eks_oidc_provider_url" {
  description = "🔑 OIDC 발급자 URL (IRSA 조건 키 생성용)"
  value       = module.eks.oidc_provider_url
}

output "eks_kubeconfig_command" {
  description = "🔑 타 직군 인계용 — 이 명령 하나로 kubectl 접속 설정"
  value       = module.eks.kubeconfig_command
}


# ------------------------------------------------------------
# ECR
# ------------------------------------------------------------
# 루트 output을 통해 CI 및 담당자에게 전달한다.
# 같은 루트의 다른 모듈은 module.ecr.repository_arns 등을 입력으로 참조한다.
output "ecr_repository_urls" {
  description = "레포명 => ECR URL (docker push 대상)"
  value       = module.ecr.repository_urls
}

output "ecr_repository_arns" {
  description = "레포명 => ARN (IAM 정책 Resource 스코프용)"
  value       = module.ecr.repository_arns
}

output "ecr_registry_id" {
  description = "ECR 레지스트리(계정) ID"
  value       = module.ecr.registry_id
}

# ------------------------------------------------------------
# ⑦ 노드그룹
# ------------------------------------------------------------

output "nodes_role_arn" {
  description = "노드 IAM 역할 ARN. ⑧ 에서 정책 추가·access entry 확인에 쓴다."
  value       = module.eks_nodes.node_role_arn
}

output "nodes_group_names" {
  description = "생성된 노드그룹 이름 목록 (인계 문서 재료)"
  value       = module.eks_nodes.node_group_names
}

output "nodes_autoscaling_group_names" {
  description = "노드그룹 키 → AutoScaling 그룹 이름. 10/1~10/4 노드 내리기 때 대상 확인용."
  value       = module.eks_nodes.autoscaling_group_names
}

output "nodes_gpu_scale_up_hint" {
  description = "GPU 기동 절차 안내. terraform output nodes_gpu_scale_up_hint 로 확인."
  value       = module.eks_nodes.gpu_scale_up_hint
}

# ------------------------------------------------------------
# ⑧ EKS 애드온
# ------------------------------------------------------------

output "addons_installed" {
  description = "설치된 애드온 목록 (인계 문서 재료)"
  value       = module.eks_addons.installed_addons
}

output "addons_network_policy_enabled" {
  description = <<-EOT
    NetworkPolicy 시행 설정값.
    🔴 true 여도 "설정"일 뿐입니다. 실제 차단은 노드에서 확인하세요 (작업 규칙 21):
       kubectl -n kube-system get ds aws-node -o yaml | grep -i networkpolicy
  EOT
  value       = module.eks_addons.network_policy_enabled
}

output "addons_ebs_csi_installed" {
  description = "🔴 false 면 CNPG PVC 가 Pending 에서 멈춥니다 (IRSA 머지 후 true 로)."
  value       = module.eks_addons.ebs_csi_installed
}

# ------------------------------------------------------------
# s3-images / CloudFront
# ------------------------------------------------------------

output "images_bucket_id" {
  description = "images 버킷 이름"
  value       = module.s3_images.bucket_id
}

output "images_bucket_arn" {
  description = "images 버킷 ARN"
  value       = module.s3_images.bucket_arn
}

output "images_cloudfront_domain_name" {
  description = "BE(image-base-url)이 Parameter Store에서 참조하는 CloudFront 배포 도메인"
  value       = module.cloudfront_images.distribution_domain_name
}

output "images_cloudfront_distribution_id" {
  description = "CloudFront 배포 ID (캐시 무효화 등에 사용)"
  value       = module.cloudfront_images.distribution_id
}


# ⑩ EDGE — 실환경 생성 후 네이티브 담당자에게 전달한다.
output "alb_arn" {
  description = "환경별 ALB ARN"
  value       = module.alb.alb_arn
}

output "alb_dns_name" {
  value = module.alb.alb_dns_name
}

output "alb_certificate_arn" {
  value = module.acm_alb.certificate_arn
}

output "waf_web_acl_arn" {
  value = module.waf.web_acl_arn
}

output "backend_networking" {
  description = "platform/networking/{stage,prod}.yaml 인계값. Controller/IRSA/CRD 확인 후 enabled=true 및 수동 Sync는 네이티브 담당."
  value = {
    targetGroupARN = module.alb.target_group_arn
    vpcID          = module.network.vpc_id
    albSourceCidrs = [for az in var.vpc_az_suffixes : var.vpc_subnet_cidrs.public[az]]
  }
}
