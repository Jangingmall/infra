# ============================================================
# modules/eks_addons/locals.tf
# ============================================================

locals {
  name = "${var.project}-${var.env}"

  # 🔑 VPC CNI 에 넘길 설정.
  #
  #    EKS 애드온은 configuration_values 를 JSON 문자열로 받습니다.
  #    enableNetworkPolicy 는 문자열 "true"/"false" 입니다 — 불리언이 아닙니다.
  #    (AWS 애드온 스키마가 그렇게 정의돼 있어 true 로 넣으면 거부됩니다)
  vpc_cni_config = jsonencode({
    enableNetworkPolicy = var.vpc_cni_enable_network_policy ? "true" : "false"
  })
}
