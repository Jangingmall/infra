# ============================================================
# modules/eks_addons/main.tf — EKS 애드온 (IaC ⑧ 일부)
# ------------------------------------------------------------
# 무엇을 하는 물건인가 (쉽게):
#   EKS 클러스터에는 "없으면 클러스터가 제구실을 못 하는 부품" 몇 개가 있습니다.
#   네트워크(VPC CNI), 이름 해석(CoreDNS), 서비스 라우팅(kube-proxy), 디스크(EBS CSI).
#
#   이걸 직접 Helm 으로 깔 수도 있지만, AWS 가 "애드온" 이라는 이름으로
#   버전 호환·업그레이드를 대신 관리해 줍니다. 그쪽이 훨씬 안전합니다.
#
# 💰 애드온 자체는 무료입니다. 다만 EBS CSI 가 만드는 EBS 볼륨은 과금됩니다.
#
# ------------------------------------------------------------
# 🔴 이 파일에서 가장 중요한 한 줄
#
#   vpc-cni 의 enableNetworkPolicy = "true"
#
#   이게 없으면 CN(박명수님) PR #24 의 NetworkPolicy 전부가
#   **에러 없이 무시**됩니다. 리소스는 만들어지는데 아무것도 안 막습니다.
# ============================================================


# ------------------------------------------------------------
# VPC CNI — Pod 네트워크 + NetworkPolicy 시행
# ------------------------------------------------------------
resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = var.cluster_name
  addon_name    = "vpc-cni"
  addon_version = var.vpc_cni_version

  configuration_values = local.vpc_cni_config

  # 🔑 EKS 가 클러스터 생성 시 이미 self-managed 로 깔아둔 것을 "인수" 합니다.
  #    OVERWRITE 가 없으면 "이미 존재한다" 며 실패합니다.
  resolve_conflicts_on_create = "OVERWRITE"

  # 업데이트 때도 우리 설정(enableNetworkPolicy)이 이기게 합니다.
  # PRESERVE 로 두면 클러스터에 남아 있던 옛 설정이 살아남아
  # "코드는 켰는데 실물은 꺼져 있는" 불일치가 생깁니다. (작업 규칙 21)
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Name = "${local.name}-addon-vpc-cni"
  }
}


# ------------------------------------------------------------
# CoreDNS — 클러스터 안의 이름 해석
# ------------------------------------------------------------
# 🔴 Pod 로 도는 Deployment 라 노드가 없으면 Pending 입니다.
#    node_group_dependency 로 노드그룹을 먼저 만들게 합니다.
resource "aws_eks_addon" "coredns" {
  count = var.manage_coredns_kube_proxy ? 1 : 0

  cluster_name  = var.cluster_name
  addon_name    = "coredns"
  addon_version = var.coredns_version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Name = "${local.name}-addon-coredns"
  }

  lifecycle {
    precondition {
      condition     = var.node_group_dependency != null
      error_message = "CoreDNS 는 노드가 있어야 뜹니다. node_group_dependency 에 module.eks_nodes 출력을 넘기세요."
    }
  }
}


# ------------------------------------------------------------
# kube-proxy — Service 를 실제 Pod IP 로 연결
# ------------------------------------------------------------
resource "aws_eks_addon" "kube_proxy" {
  count = var.manage_coredns_kube_proxy ? 1 : 0

  cluster_name  = var.cluster_name
  addon_name    = "kube-proxy"
  addon_version = var.kube_proxy_version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Name = "${local.name}-addon-kube-proxy"
  }
}


# ------------------------------------------------------------
# EBS CSI Driver — PVC 를 실제 EBS 볼륨으로
# ------------------------------------------------------------
# 🔴 이게 없으면 CNPG Pod 3개가 전부 안 뜹니다.
#
#    박명수님이 k8s/base/storage/gp3-cnpg-storageclass.yaml 로 StorageClass 를
#    올려두셨는데, StorageClass 는 "디스크를 이렇게 만들어 달라" 는 **주문서**일 뿐입니다.
#    실제로 EBS 를 만드는 **직원(EBS CSI Driver)** 과 그 직원의 **AWS 권한(IRSA)** 이
#    없으면 PVC 가 Pending 에서 영원히 멈춥니다.
#
#    ⚠️ EKS 1.23 부터 쿠버네티스 내장 EBS 프로비저너가 제거되어
#       StorageClass 만으로는 동작하지 않습니다.
resource "aws_eks_addon" "ebs_csi" {
  count = var.ebs_csi_enabled ? 1 : 0

  cluster_name  = var.cluster_name
  addon_name    = "aws-ebs-csi-driver"
  addon_version = var.ebs_csi_version

  # 🔑 Pod 단위 권한. 노드 역할에 EBS 권한을 붙이는 우회를 쓰지 않는 이유는
  #    그 노드의 모든 Pod 가 EBS 를 조작할 수 있게 되기 때문입니다.
  service_account_role_arn = var.ebs_csi_irsa_role_arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Name = "${local.name}-addon-ebs-csi"
  }

  lifecycle {
    precondition {
      condition     = var.ebs_csi_irsa_role_arn != null && var.ebs_csi_irsa_role_arn != ""
      error_message = "EBS CSI 를 켜려면 ebs_csi_irsa_role_arn 이 필요합니다. IRSA 없이 설치하면 볼륨 생성 권한이 없어 PVC 가 Pending 에서 멈춥니다."
    }

    precondition {
      condition     = var.node_group_dependency != null
      error_message = "EBS CSI 컨트롤러도 Pod 라 노드가 있어야 뜹니다. node_group_dependency 를 넘기세요."
    }
  }
}
