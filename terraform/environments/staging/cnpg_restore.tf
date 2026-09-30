variable "cnpg_restore_enabled" {
  type    = bool
  default = false
}

variable "cnpg_restore_name" {
  type    = string
  default = "jangingmall-restore-audit-20260930"
  validation {
    condition     = can(regex("^jangingmall-restore-[a-z0-9-]+$", var.cnpg_restore_name))
    error_message = "Use a separate restore identity."
  }
}

variable "cnpg_restore_namespace" {
  type    = string
  default = "database"
}

data "aws_iam_policy_document" "cnpg_restore" {
  count = var.cnpg_restore_enabled ? 1 : 0
  statement {
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::jangin-${var.env}-s3-backup"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["cnpg/staging", "cnpg/staging/*"]
    }
  }
  statement {
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::jangin-${var.env}-s3-backup/cnpg/staging/*"]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = [module.kms_app.key_arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"]
    }
  }
}

module "cnpg_restore_irsa" {
  source            = "../../modules/irsa"
  count             = var.cnpg_restore_enabled ? 1 : 0
  project           = var.project
  env               = var.env
  name              = "cnpg-restore"
  namespace         = var.cnpg_restore_namespace
  service_account   = var.cnpg_restore_name
  policy_json       = data.aws_iam_policy_document.cnpg_restore[0].json
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
}

output "cnpg_restore_role_arn" {
  value = try(module.cnpg_restore_irsa[0].role_arn, null)
}
