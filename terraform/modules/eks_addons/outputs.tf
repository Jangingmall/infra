# ============================================================
# modules/eks_addons/outputs.tf
# ============================================================

output "vpc_cni_version" {
  description = "설치된 VPC CNI 버전 (인계 문서 재료)"
  value       = aws_eks_addon.vpc_cni.addon_version
}

output "network_policy_enabled" {
  description = <<-EOT
    NetworkPolicy 시행 여부. CN NetworkPolicy 가 실제로 동작하는지의 전제 조건.
    🔴 true 여도 "설정"일 뿐이라, 실제 차단은 노드에서 직접 확인해야 합니다:
       kubectl -n kube-system get ds aws-node -o yaml | grep -i networkpolicy
  EOT
  value       = var.vpc_cni_enable_network_policy
}

output "ebs_csi_installed" {
  description = "EBS CSI 설치 여부. false 면 CNPG PVC 가 Pending 에서 멈춥니다."
  value       = var.ebs_csi_enabled
}

output "installed_addons" {
  description = "설치된 애드온 이름 목록 (인계 문서 재료)"
  value = compact([
    aws_eks_addon.vpc_cni.addon_name,
    try(aws_eks_addon.coredns[0].addon_name, ""),
    try(aws_eks_addon.kube_proxy[0].addon_name, ""),
    try(aws_eks_addon.ebs_csi[0].addon_name, ""),
  ])
}
