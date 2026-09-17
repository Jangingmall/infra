module "endpoints" {
  source = "../../modules/endpoints"

  project = var.project
  env     = var.env
  region  = var.region

  vpc_id = module.network.vpc_id

  route_table_ids = module.network.route_table_ids_for_s3_endpoint
}
