# ============================================================
# nodegroups.tf — modules/eks_nodes 호출 (IaC ⑦)   💰 유료  (staging)
# ------------------------------------------------------------
# 🔑 prod/nodegroups.tf 와 완전히 같습니다. 환경 차이는 terraform.tfvars 로만 냅니다.
#    작업 규칙 14 — prod 를 고치면 이 파일도 같이 확인하세요.
#      diff terraform/environments/prod/nodegroups.tf \
#           terraform/environments/staging/nodegroups.tf
# ------------------------------------------------------------
# 🔴 작업 규칙 17: apply 는 9/18 일괄(파트장 실행).
#
# 🔑 modules/eks 와 따로 둔 이유
#    컨트롤플레인은 끌 수 없는 상시 비용이고, 노드그룹은 10/1~10/4 에 내리는 대상입니다.
#    "끌 수 있는 것"과 "끌 수 없는 것"의 경계가 모듈 경계와 일치하면
#    비용 보고서의 구분과 코드 구조가 같아집니다. (NAT 를 분리한 것과 같은 이유)
# ============================================================
locals {
  # workload-type 라벨 → 그 계층 노드에 붙일 SG.
  # modules/security 가 만든 SG 4종이 여기서 비로소 노드에 연결됩니다.
  #
  # ⚠️ system 과 app 이 같은 sg-eks-node 를 쓰는 것은 의도입니다.
  #    sg-eks-node 의 9090 self-scrape 규칙은 "같은 SG 를 단 것끼리" 이므로,
  #    system 노드의 Prometheus 가 app 노드를 스크레이프하려면 같은 SG 여야 합니다.
  #    Redis(6379)·DB(5432)·GPU(8000) 같은 노드 간 통신은
  #    EKS 클러스터 SG 가 이미 전 포트를 열어두므로 별도 규칙이 필요 없습니다.
  node_security_groups_by_workload = {
    system = [module.security.eks_node_id]
    app    = [module.security.eks_node_id]
    db     = [module.security.db_id]
    gpu    = [module.security.eks_gpu_id]
  }
}

module "eks_nodes" {
  source = "../../modules/eks_nodes"

  project = var.project
  env     = var.env

  # ⑥ 에서 만든 클러스터에 붙습니다. 이 참조가 곧 실행 순서입니다.
  cluster_name    = module.eks.cluster_name
  cluster_version = var.eks_cluster_version

  # 🔴 클러스터 SG. LT 에 SG 를 지정하면 EKS 가 이걸 자동으로 안 붙입니다.
  #    빠지면 노드가 컨트롤플레인과 통신하지 못해 NotReady 로 멈춥니다.
  cluster_security_group_id        = module.eks.cluster_security_group_id
  security_groups_by_workload_type = local.node_security_groups_by_workload

  # 🔴 노드는 app(private) 서브넷에만 둡니다.
  #    public 에 두면 노드가 공인 IP 를 갖게 되어 인터넷에서 직접 닿습니다.
  #    아웃바운드는 ⑤ NAT Gateway 로 나갑니다.
  # NAT와 같은 AZ의 app 서브넷만 사용한다(기본 AZ-a).
  subnet_ids = [module.network.app_subnet_ids_by_az[var.nat_gateway_az]]

  node_groups                 = var.nodes_groups
  node_role_extra_policy_arns = var.nodes_extra_policy_arns
  ssh_key_name                = var.nodes_ssh_key_name
}
