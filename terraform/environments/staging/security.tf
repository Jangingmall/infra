module "security" {
  source = "../../modules/security"

  project = var.project
  env     = var.env
  region  = var.region

  vpc_id = module.network.vpc_id
}
