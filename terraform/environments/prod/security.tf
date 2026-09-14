# ============================================================
# security.tf — modules/security 호출 (IaC ③)
# ------------------------------------------------------------
# SG 4종(sg-alb / sg-eks-node / sg-db / sg-eks-gpu) + 규칙 15개.
# 전부 CIDR 이 아니라 Security Group Reference 로 연결한다. (작업 규칙 5)
# ============================================================

module "security" {
  source = "../../modules/security"

  project = var.project
  env     = var.env
  region  = var.region

  # ↓ 여기가 모듈 간 연결선.
  #   modules/security 안에서 aws_vpc.main.id 를 직접 쓰면
  #   그 모듈은 네트워크 모듈 없이는 못 쓰는 물건이 된다.
  #   반드시 "network 의 output → security 의 variable" 로 전달한다.
  vpc_id = module.network.vpc_id
}
