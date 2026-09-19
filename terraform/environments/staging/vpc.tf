module "network" {
  source = "../../modules/network"

  project = var.project
  env     = var.env
  region  = var.region

  vpc_cidr     = var.vpc_cidr
  az_suffixes  = var.vpc_az_suffixes
  subnet_cidrs = var.vpc_subnet_cidrs

  cluster_name = var.eks_cluster_name

  flow_log_destination = "${module.s3_logs.bucket_arn}/vpc-flow/"
}
