# ============================================================
# modules/eks_nodes/outputs.tf
# ============================================================

output "node_role_arn" {
  description = <<-EOT
    노드 IAM 역할 ARN.
    🔑 인증 모드가 API 라서, 노드가 클러스터에 조인하려면 이 역할에 대한
       access entry 가 필요할 수 있습니다. 관리형 노드그룹은 AWS 가 자동으로
       처리하지만, 수동 확인이 필요할 때 이 값을 씁니다.
  EOT
  value       = aws_iam_role.node.arn
}

output "node_role_name" {
  description = "노드 IAM 역할 이름. ⑧ 에서 정책을 추가로 붙일 때 쓴다."
  value       = aws_iam_role.node.name
}

output "node_group_names" {
  description = "생성된 노드그룹 이름 목록"
  value       = [for g in aws_eks_node_group.this : g.node_group_name]
}

output "node_group_arns" {
  description = "노드그룹 키 → ARN map"
  value       = { for k, g in aws_eks_node_group.this : k => g.arn }
}

output "autoscaling_group_names" {
  description = <<-EOT
    노드그룹 키 → AutoScaling 그룹 이름 map.
    🔑 10/1~10/4 노드 내리기 때 이 이름으로 대상을 확인합니다.
       다만 실제 조정은 콘솔·CLI 가 아니라 terraform.tfvars 의 desired_size 를
       고쳐서 하는 것이 원칙입니다 (코드에 흔적이 남아야 다음 사람이 압니다).
  EOT
  value = {
    for k, g in aws_eks_node_group.this :
    k => try(g.resources[0].autoscaling_groups[0].name, null)
  }
}

output "gpu_scale_up_hint" {
  description = <<-EOT
    GPU 를 켜는 방법 안내. AI팀 요청이 오면 이 순서로 합니다.
    (terraform output 으로 꺼내 보면 절차를 안 찾아도 됩니다)
  EOT
  value       = <<-EOT
    GPU 노드 기동 절차
      1. terraform.tfvars 에서 nodes_groups 의 gpu-a / gpu-b 를
         desired_size = 0 → 1 로 변경
      2. terraform plan  (변경이 노드그룹 2개뿐인지 확인)
      3. terraform apply
      4. 기동 확인: kubectl get nodes -l workload-type=gpu

    💰 g6e.xlarge 약 $2.29/h · g4dn.xlarge 약 $0.65/h — 둘 다 켜면 시간당 약 $2.94.
       테스트가 끝나면 반드시 0 으로 되돌립니다.
  EOT
}
