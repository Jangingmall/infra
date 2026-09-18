# ============================================================
# addons.tf — modules/eks_addons 호출 (IaC ⑧ 일부)  (staging)
# ------------------------------------------------------------
# 🔑 prod/addons.tf 와 동일합니다. 환경 차이는 terraform.tfvars 로만 냅니다.
#    작업 규칙 14 — prod 를 고치면 이 파일도 확인하세요.
# ------------------------------------------------------------
# 🔑 애드온 자체는 무료입니다. 다만 EBS CSI 가 만드는 볼륨은 과금됩니다.
#
# 🔴 여기서 가장 중요한 값: addons_vpc_cni_enable_network_policy
#    이걸 켜지 않으면 CN(박명수님) NetworkPolicy 전부가 에러 없이 무시됩니다.
# ============================================================

module "eks_addons" {
  source = "../../modules/eks_addons"

  project = var.project
  env     = var.env

  cluster_name = module.eks.cluster_name

  # ── VPC CNI ───────────────────────────────────────────────
  vpc_cni_version               = var.addons_vpc_cni_version
  vpc_cni_enable_network_policy = var.addons_vpc_cni_enable_network_policy

  # ── CoreDNS · kube-proxy ──────────────────────────────────
  manage_coredns_kube_proxy = var.addons_manage_coredns_kube_proxy
  coredns_version           = var.addons_coredns_version
  kube_proxy_version        = var.addons_kube_proxy_version

  # ── EBS CSI Driver ────────────────────────────────────────
  # ✅ 2026-09-19: IRSA(PR #32) 머지로 활성화.
  #    role_arn 은 apply 시점에 정해지는 값이라 terraform.tfvars(리터럴 전용)에는
  #    쓸 수 없고, 여기서 모듈 output 을 직접 참조한다.
  #    🔴 EKS 1.23+ 는 in-tree EBS 프로비저너가 제거되어, 애드온과 IRSA 권한이
  #       둘 다 있어야 PVC 가 Bound 된다. 하나만 있으면 Pending 에서 멈춘다.
  ebs_csi_enabled       = var.addons_ebs_csi_enabled
  ebs_csi_version       = var.addons_ebs_csi_version
  ebs_csi_irsa_role_arn = module.irsa["ebs-csi"].role_arn

  # 🔑 노드가 먼저 떠야 CoreDNS·EBS CSI 컨트롤러 Pod 가 뜹니다.
  #    이 참조 한 줄이 순서를 만듭니다.
  node_group_dependency = module.eks_nodes.node_group_names
}
