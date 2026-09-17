locals {
  name = "${var.project}-${var.env}"

  common_tags = {
    Project     = var.project
    Environment = var.env
    ManagedBy   = "Terraform"
    Owner       = "infra"
  }
}
