module "nat" {
  source = "../../modules/nat"

  project = var.project
  env     = var.env

  enabled              = var.nat_enabled
  az_suffix            = var.nat_gateway_az
  alarm_sns_topic_arns = var.nat_alarm_sns_topic_arns

  public_subnet_ids_by_az = module.network.public_subnet_ids_by_az

  app_route_table_id = module.network.app_route_table_id

  internet_gateway_id = module.network.internet_gateway_id
}
