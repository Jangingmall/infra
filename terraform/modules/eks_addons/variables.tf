# ============================================================
# modules/eks_addons/variables.tf
# ------------------------------------------------------------
# 🔴 모듈 변수에 default 를 두지 않습니다. (검수 체크리스트 14)
# ============================================================

variable "project" {
  description = "프로젝트 식별자 (예: jangin)"
  type        = string
}

variable "env" {
  description = "환경 구분. prod | staging"
  type        = string

  validation {
    condition     = contains(["prod", "staging"], var.env)
    error_message = "env 는 prod 또는 staging 만 허용합니다."
  }
}

variable "cluster_name" {
  description = "애드온을 설치할 EKS 클러스터 이름"
  type        = string
}

# ------------------------------------------------------------
# VPC CNI
# ------------------------------------------------------------

variable "vpc_cni_version" {
  description = <<-EOT
    VPC CNI 애드온 버전. null 이면 클러스터 버전에 맞는 AWS 기본값을 씁니다.
    확인: aws eks describe-addon-versions --kubernetes-version <ver> --addon-name vpc-cni
  EOT
  type        = string
}

variable "vpc_cni_enable_network_policy" {
  description = <<-EOT
    🔴 EKS 에서 NetworkPolicy 를 실제로 "시행" 할지.

    쿠버네티스에서 NetworkPolicy 는 **선언**일 뿐이고, 실제로 막는 것은 CNI 플러그인입니다.
    이 값을 켜지 않으면 NetworkPolicy 리소스는 정상 생성되지만 **아무것도 막지 않습니다.**
    🔴 에러도 경고도 나지 않습니다.

    비유하자면 "출입금지 표지판은 붙였는데 경비원이 없는" 상태입니다.
    kubectl get networkpolicy 로 보면 멀쩡히 있어서 됐다고 착각하기 쉽고,
    보안팀 검수에서 "차단 테스트를 해보니 다 뚫린다" 로 발견됩니다.

    🔗 CN(박명수님) PR #24 의 NetworkPolicy 전부가 이 값 하나에 달려 있습니다.

    검증: kubectl -n kube-system get ds aws-node -o yaml | grep -i networkpolicy
    ⚠️ 시행 주체가 노드의 에이전트라 노드가 뜬 뒤에야 동작합니다.
  EOT
  type        = bool
}

# ------------------------------------------------------------
# EBS CSI Driver
# ------------------------------------------------------------

variable "ebs_csi_enabled" {
  description = <<-EOT
    EBS CSI Driver 애드온 설치 여부.

    🔴 IRSA 역할이 선행조건입니다(아래 ebs_csi_irsa_role_arn).
       IRSA 없이 설치하면 드라이버가 AWS 에 볼륨 생성을 요청할 권한이 없어
       PVC 가 Pending 에서 멈춥니다. 증상이 "설치는 됐는데 동작 안 함" 이라 헷갈립니다.

    → IRSA(박다정님 modules/irsa)가 머지되기 전까지는 false 로 둡니다.
  EOT
  type        = bool
}

variable "ebs_csi_version" {
  description = "EBS CSI 애드온 버전. null 이면 AWS 기본값."
  type        = string
}

variable "ebs_csi_irsa_role_arn" {
  description = <<-EOT
    EBS CSI 컨트롤러가 사용할 IRSA 역할 ARN
    (ServiceAccount: kube-system/ebs-csi-controller-sa).

    🔴 노드 IAM 역할에 EBS 권한을 통째로 붙이는 우회는 쓰지 않습니다.
       그러면 그 노드에 뜬 모든 Pod 가 EBS 를 조작할 수 있게 됩니다 — 보안팀 검수 지적 대상.

    🔗 박다정님 modules/irsa 의 출력을 넘깁니다.
  EOT
  type        = string
}

# ------------------------------------------------------------
# CoreDNS · kube-proxy
# ------------------------------------------------------------

variable "coredns_version" {
  description = "CoreDNS 애드온 버전. null 이면 AWS 기본값."
  type        = string
}

variable "kube_proxy_version" {
  description = "kube-proxy 애드온 버전. null 이면 AWS 기본값."
  type        = string
}

variable "manage_coredns_kube_proxy" {
  description = <<-EOT
    CoreDNS·kube-proxy 를 Terraform 관리로 가져올지.

    EKS 는 클러스터를 만들 때 이 둘을 자체적으로 설치합니다(self-managed).
    true 로 두면 Terraform 이 그것을 "인수" 해서 버전을 코드로 관리합니다.

    💡 인수하면 좋은 점: 버전이 코드에 남아 팀원이 같은 상태를 재현할 수 있습니다.
    ⚠️ 인수할 때 resolve_conflicts_on_create = OVERWRITE 가 필요합니다
       — 이미 있는 설정을 애드온 기본값으로 덮어쓴다는 뜻입니다.
  EOT
  type        = bool
}

# ------------------------------------------------------------
# 순서
# ------------------------------------------------------------

variable "node_group_dependency" {
  description = <<-EOT
    노드그룹이 먼저 만들어지게 하려고 받는 값. 내용은 쓰지 않습니다.

    CoreDNS 는 Pod 로 도는 Deployment 라 노드가 없으면 Pending 입니다.
    애드온 설치 자체는 성공하지만 "Degraded" 상태로 남아 plan 이 지저분해집니다.
    module.eks_nodes 의 출력을 넘겨 순서를 만듭니다.
  EOT
  type        = any
}
