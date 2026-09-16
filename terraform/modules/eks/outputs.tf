# ============================================================
# modules/eks/outputs.tf
# ============================================================

output "cluster_name" {
  description = "EKS 클러스터 이름"
  value       = aws_eks_cluster.main.name
}

output "cluster_arn" {
  description = "클러스터 ARN"
  value       = aws_eks_cluster.main.arn
}

output "cluster_version" {
  description = "실제로 생성된 쿠버네티스 버전"
  value       = aws_eks_cluster.main.version
}

output "cluster_endpoint" {
  description = "컨트롤플레인 API 주소. kubectl 이 말을 거는 곳입니다."
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_certificate_authority_data" {
  description = "kubeconfig 에 들어가는 CA 인증서(base64). 민감값은 아니지만 길어서 sensitive 로 가립니다."
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "cluster_security_group_id" {
  description = <<-EOT
    🔑 EKS 가 자동 생성한 클러스터 SG (eks-cluster-sg-<이름>).

    **3-tier 방어 논리의 핵심 근거입니다.**
    이 SG 는 같은 클러스터의 노드끼리 전 포트를 허용하므로,
    app 노드와 DB 노드를 서로 다른 서브넷에 둬도 SG 단에서는 이미 열려 있습니다.
    → 계층 격리는 서브넷이 아니라 노드그룹·Taint·SG·NetworkPolicy 축으로 이뤄집니다.
  EOT
  value = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "cluster_iam_role_arn" {
  description = "컨트롤플레인 IAM 역할 ARN"
  value       = aws_iam_role.cluster.arn
}

output "oidc_provider_arn" {
  description = "🔑 OIDC Provider ARN — ⑧ IRSA 6종의 신뢰 정책에 들어갑니다."
  value       = aws_iam_openid_connect_provider.oidc.arn
}

output "oidc_provider_url" {
  description = <<-EOT
    🔑 OIDC 발급자 URL (https:// 포함).
    IRSA 신뢰 정책의 조건 키를 만들 때는 https:// 를 뗀 형태를 씁니다 —
    ⑧ 에서 replace(url, "https://", "") 로 처리합니다.
  EOT
  value = aws_iam_openid_connect_provider.oidc.url
}

output "kubeconfig_command" {
  description = "🔑 타 직군 인계용 — 이 명령 하나로 kubectl 접속이 설정됩니다."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.main.name} --profile <본인 SSO 프로필>"
}
