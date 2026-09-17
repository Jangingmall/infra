# ============================================================
# modules/eks_nodes/locals.tf
# ============================================================

locals {
  # 리소스 이름 접두사 → "jangin-prod" / "jangin-staging"
  name = "${var.project}-${var.env}"

  # 🔑 "켜진 그룹만" 실제로 만듭니다.
  #
  #    ⚠️ enabled = false 와 desired_size = 0 은 완전히 다릅니다.
  #       enabled = false  → 노드그룹 자체를 안 만듦 (주차장을 안 지음)
  #       desired_size = 0 → 노드그룹은 있고 EC2 만 0대 (주차장은 있고 차만 없음)
  #
  #    GPU 는 후자입니다. 정의는 다 해두고 값 하나로 기동할 수 있게 둡니다.
  enabled_groups = { for k, g in var.node_groups : k => g if g.enabled }

  # 노드 IAM 역할에 항상 붙는 관리형 정책 4종
  base_node_policies = {
    # 노드가 클러스터에 조인하고 kubelet 이 API 서버와 통신
    worker = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"

    # VPC CNI 가 Pod 에 VPC 실제 IP 를 붙임
    cni = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"

    # 🔴 ECR 이미지 pull. 없으면 Pod 가 ImagePullBackOff
    ecr = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"

    # 🔴 SSM Session Manager.
    #    9/21 엔드포인트 private only 전환 후 클러스터에 접근하는 유일한 통로입니다.
    #    Bastion 을 만들지 않기로 한 설계라, 이게 빠지면
    #    "클러스터는 떴는데 들어갈 방법이 없는" 상태가 됩니다.
    ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}
