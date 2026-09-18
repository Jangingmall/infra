# ============================================================
# eks_access.tf — EKS 클러스터 접근 권한 (staging)
# ------------------------------------------------------------
# staging/prod는 클러스터가 물리적으로 분리돼 있어
# namespace가 아닌 cluster 단위로 access_scope 지정.
# ============================================================

resource "aws_eks_access_entry" "backend_dev" {
  cluster_name  = module.eks.cluster_name
  principal_arn = "arn:aws:iam::750240012008:role/aws-reserved/sso.amazonaws.com/ap-northeast-2/AWSReservedSSO_Backend-Dev_6a9f764ae23f20d3"
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "backend_dev_edit" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_eks_access_entry.backend_dev.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type = "cluster"
  }
}

resource "aws_eks_access_entry" "infra_admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = "arn:aws:iam::750240012008:role/aws-reserved/sso.amazonaws.com/ap-northeast-2/AWSReservedSSO_Infra-Admin_1cd0c318411b99b6"
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "infra_admin_cluster" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_eks_access_entry.infra_admin.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

resource "aws_eks_access_entry" "security_audit" {
  cluster_name  = module.eks.cluster_name
  principal_arn = "arn:aws:iam::750240012008:role/aws-reserved/sso.amazonaws.com/ap-northeast-2/AWSReservedSSO_Security-Audit_47bd66eed9bc2604"
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "security_audit_view" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_eks_access_entry.security_audit.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"

  access_scope {
    type = "cluster"
  }
}