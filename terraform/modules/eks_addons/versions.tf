# ============================================================
# modules/eks_addons/versions.tf
# ============================================================

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}
