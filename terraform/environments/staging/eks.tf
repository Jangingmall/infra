module "eks" {
  source = "../../modules/eks"

  project = var.project
  env     = var.env
  region  = var.region

  cluster_name    = var.eks_cluster_name
  cluster_version = var.eks_cluster_version

  subnet_ids = module.network.app_subnet_ids

  additional_security_group_ids = var.eks_additional_security_group_ids

  endpoint_public_access  = var.eks_endpoint_public_access
  endpoint_private_access = var.eks_endpoint_private_access
  public_access_cidrs     = var.eks_public_access_cidrs

  authentication_mode                         = var.eks_authentication_mode
  bootstrap_cluster_creator_admin_permissions = var.eks_bootstrap_creator_admin

  enabled_cluster_log_types = var.eks_enabled_log_types
  log_retention_days        = var.eks_log_retention_days

  secrets_kms_key_arn = var.eks_secrets_kms_key_arn
}
