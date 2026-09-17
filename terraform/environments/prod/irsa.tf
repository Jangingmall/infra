# ── irsa-backend ──────────────────────────────────────────────
data "aws_iam_policy_document" "backend" {
  statement {
    sid       = "SSMRead"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:ap-northeast-2:*:parameter/${var.env}/backend/*"]
  }

  statement {
    sid       = "KMSDecrypt"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.aws_kms_key.shared.arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.ap-northeast-2.amazonaws.com"]
    }
  }

  statement {
    sid     = "S3ImagesReturns"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject"]
    resources = [
      "arn:aws:s3:::jangin-${var.env}-s3-images/*",
      "arn:aws:s3:::jangin-${var.env}-s3-returns/*",
    ]
  }
}

# ── irsa-ai ───────────────────────────────────────────────────
data "aws_iam_policy_document" "ai" {
  statement {
    sid       = "SSMRead"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:ap-northeast-2:*:parameter/${var.env}/ai/*"]
  }

  statement {
    sid       = "S3ModelsRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::jangin-${var.env}-s3-models/*"]
  }
}

# ── irsa-cnpg (WAL Archive / Base Backup) ─────────────────────
data "aws_iam_policy_document" "cnpg" {
  statement {
    sid     = "S3Backup"
    effect  = "Allow"
    actions = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::jangin-${var.env}-s3-backup",
      "arn:aws:s3:::jangin-${var.env}-s3-backup/*",
    ]
  }

  statement {
    sid       = "KMSForBackup"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [var.aws_kms_key.shared.arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.ap-northeast-2.amazonaws.com"]
    }
  }
}

# ── irsa-loki ──────────────────────────────────────────────────
data "aws_iam_policy_document" "loki" {
  statement {
    sid     = "S3Logs"
    effect  = "Allow"
    actions = ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:DeleteObject"]
    resources = [
      "arn:aws:s3:::jangin-${var.env}-s3-logs",
      "arn:aws:s3:::jangin-${var.env}-s3-logs/loki/*",
    ]
  }
}


# ── irsa-alb-controller ────────────────────────────────────────
# ⚠️ modules/alb 안에서 이미 aws-load-balancer-controller용 IAM을 만들고 있는지 먼저 확인!
resource "aws_iam_policy" "alb_controller" {
  name   = "${var.project}-${var.env}-irsa-policy-alb-controller"
  policy = file("${path.module}/policies/alb-controller-policy.json")
}

locals {
  irsa_roles = {
    # ── IRSA 6종 (설계 문서 3-3 표 기준) ──
    backend = {
      namespace           = "app"
      service_account     = "backend-sa"
      policy_json         = data.aws_iam_policy_document.backend.json
      managed_policy_arns = []
    }
    ai = {
      namespace           = "ai"
      service_account     = "ai-worker-sa"
      policy_json         = data.aws_iam_policy_document.ai.json
      managed_policy_arns = []
    }
    cnpg = {
      namespace           = "database"
      service_account     = "cnpg-backup-sa"
      policy_json         = data.aws_iam_policy_document.cnpg.json
      managed_policy_arns = []
    }
    loki = {
      namespace           = "monitoring"
      service_account     = "loki-sa"
      policy_json         = data.aws_iam_policy_document.loki.json
      managed_policy_arns = []
    }
    ebs-csi = {
      namespace           = "kube-system"
      service_account     = "ebs-csi-controller-sa"
      policy_json         = null
      managed_policy_arns = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
    }
    alb-controller = {
      namespace           = "kube-system"
      service_account     = "aws-load-balancer-controller"
      policy_json         = null
      managed_policy_arns = [aws_iam_policy.alb_controller.arn]
    }
    # secrets-csi ⏸ 보류 (위 data 블록 주석 참고) — 확정되면 여기 항목 추가
    # karpenter는 미사용 확정이라 제외
  }
}

module "irsa" {
  source   = "../../modules/irsa"
  for_each = local.irsa_roles

  project             = var.project
  env                 = var.env
  name                = each.key
  namespace           = each.value.namespace
  service_account     = each.value.service_account
  policy_json         = each.value.policy_json
  managed_policy_arns = each.value.managed_policy_arns
  oidc_provider_arn   = module.eks.oidc_provider_arn
  oidc_provider_url   = module.eks.oidc_provider_url
}