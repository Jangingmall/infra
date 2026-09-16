# ============================================================
# eks.tf — modules/eks 호출 (IaC ⑥)   💰 유료
# ------------------------------------------------------------
# 🔴 EKS 컨트롤플레인은 시간당 요금이 붙고 끌 수 없습니다.
#    노드를 전부 내려도 클러스터가 있으면 과금됩니다.
#    작업 규칙 17 — apply 는 9/18 일괄.
#
# 🔴 아래 3개 값은 되돌릴 수 없는 결정이라 팀 확정이 필요합니다.
#    (「EKS 클러스터 결정 안건」 문서 참조 · 9/16 회의 대상)
#      eks_cluster_version       버전은 올릴 수만 있고 내릴 수 없음
#      eks_authentication_mode   좁히는 방향으로만 변경 가능
#      eks_endpoint_*            변경은 가능하나 5~10분 중단
# ============================================================

module "eks" {
  source = "../../modules/eks"

  project = var.project
  env     = var.env
  region  = var.region

  cluster_name    = var.eks_cluster_name
  cluster_version = var.eks_cluster_version

  # 컨트롤플레인 ENI 는 app(private) 서브넷에 둡니다.
  # 🔴 서로 다른 AZ 2개 이상이 EKS 필수 요구사항입니다.
  subnet_ids = module.network.app_subnet_ids

  # 비워 둡니다 — EKS 가 eks-cluster-sg-<이름> 을 자동 생성합니다.
  additional_security_group_ids = var.eks_additional_security_group_ids

  endpoint_public_access  = var.eks_endpoint_public_access
  endpoint_private_access = var.eks_endpoint_private_access
  public_access_cidrs     = var.eks_public_access_cidrs

  authentication_mode                         = var.eks_authentication_mode
  bootstrap_cluster_creator_admin_permissions = var.eks_bootstrap_creator_admin

  enabled_cluster_log_types = var.eks_enabled_log_types
  log_retention_days        = var.eks_log_retention_days

  # ⑧ KMS 단계에서 채웁니다. 🔴 생성 후 해제 불가.
  secrets_kms_key_arn = var.eks_secrets_kms_key_arn
}
