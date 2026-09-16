# ============================================================
# modules/security/outputs.tf
# ------------------------------------------------------------
# ⑥ EKS · ⑦ 노드그룹 · ⑩ ALB 단계에서 이 ID들을 받아 쓴다.
# ============================================================

output "alb_id" {
  description = "sg-alb — 인터넷에서 들어오는 443/80 을 받는 SG. 🔴 9090 금지 (작업 규칙 6)"
  value       = aws_security_group.alb.id
}

output "eks_node_id" {
  description = "sg-eks-node — EKS 워커노드 SG. ⑦ 노드그룹에서 받아 쓴다."
  value       = aws_security_group.eks_node.id
}

output "db_id" {
  description = "sg-db — CNPG DB 노드 SG. sg-eks-node 로부터 5432 만 허용."
  value       = aws_security_group.db.id
}

output "eks_gpu_id" {
  description = "sg-eks-gpu — AI GPU 노드 SG. 🔴 sg-db 로 가는 규칙을 만들지 않는다 (작업 규칙 11)"
  value       = aws_security_group.eks_gpu.id
}

output "s3_prefix_list_id" {
  description = <<-EOT
    이 리전 S3 서비스의 관리형 prefix list ID (pl-xxxx).
    endpoints 모듈·향후 규칙에서 재조회하지 않고 이 값을 쓰면
    AWS API 호출이 한 번으로 줄고 값이 갈릴 일이 없다.
  EOT
  value       = data.aws_ec2_managed_prefix_list.s3.id
}

output "security_group_ids" {
  description = "SG 이름 → ID map. 인계 문서·디버깅용 한눈 보기."
  value = {
    alb      = aws_security_group.alb.id
    eks_node = aws_security_group.eks_node.id
    db       = aws_security_group.db.id
    eks_gpu  = aws_security_group.eks_gpu.id
  }
}
