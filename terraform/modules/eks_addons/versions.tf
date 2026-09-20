# ============================================================
# modules/eks_addons/versions.tf
# ============================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}
