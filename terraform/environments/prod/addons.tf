# ============================================================
# addons.tf — modules/eks_addons 호출 (IaC ⑧ 일부)
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
  # 🔴 IRSA(박다정님 modules/irsa)가 머지되면 아래 두 줄을 바꿉니다.
  #      addons_ebs_csi_enabled       = true
  #      addons_ebs_csi_irsa_role_arn = module.irsa["ebs-csi"].role_arn
  #    그 전까지는 false 로 둡니다 — IRSA 없이 설치하면 PVC 가 Pending 에서 멈칩니다.
  ebs_csi_enabled       = var.addons_ebs_csi_enabled
  ebs_csi_version       = var.addons_ebs_csi_version
  ebs_csi_irsa_role_arn = var.addons_ebs_csi_irsa_role_arn

  # 🔑 노드가 먼저 떠야 CoreDNS·EBS CSI 컨트롤러 Pod 가 뜹니다.
  #    이 참조 한 줄이 순서를 만듭니다.
  node_group_dependency = module.eks_nodes.node_group_names
}
