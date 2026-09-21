# ── irsa-backend ──────────────────────────────────────────────
data "aws_iam_policy_document" "backend" {
  statement {
    sid    = "SSMRead"
    effect = "Allow"
    # CSI는 GetParameters를 사용한다. AI 요청 토큰은 Backend와 AI가 같은 값을 읽는다.
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.env}/backend/*",
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.env}/ai/internal-auth-token",
    ]
  }

  statement {
    sid       = "KMSDecrypt"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [module.kms_app.key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"

      # 🔴 두 서비스가 모두 필요합니다.
      #    ssm — SecureString 파라미터 복호화 (CSI 마운트)
      #    s3  — s3-returns 가 SSE-KMS(CMK) 버킷이라, PutObject/GetObject 시
      #          S3 가 backend 를 대신해 GenerateDataKey/Decrypt 를 호출합니다.
      #          이게 없으면 반품 증빙 업로드·조회가 AccessDenied 로 실패합니다.
      #    StringEquals 에 리스트를 주면 OR 로 평가됩니다.
      values = [
        "ssm.${var.region}.amazonaws.com",
        "s3.${var.region}.amazonaws.com",
      ]
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
    sid     = "SSMRead"
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters"]
    # 공유 ai-worker-sa는 앱 비밀번호만 읽는다. 벡터DB 관리자 비밀번호는 제외한다.
    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.env}/ai/internal-auth-token",
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.env}/ai/vector-db/password",
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.env}/backend/backend-auth-token",
    ]
  }

  statement {
    sid       = "KMSDecrypt"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [module.kms_app.key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }

  statement {
    sid       = "S3ModelsRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${module.s3_models.bucket_arn}/*"]
  }
}

# CSI가 워크로드 ServiceAccount의 권한으로 파일을 마운트한다.
# Redis·벡터DB에 Backend·AI의 다른 파라미터나 S3 접근 권한을 공유하지 않는다.
data "aws_iam_policy_document" "redis" {
  statement {
    sid       = "SSMRead"
    effect    = "Allow"
    actions   = ["ssm:GetParameters"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.env}/backend/redis-password"]
  }

  statement {
    sid       = "KMSDecrypt"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [module.kms_app.key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ai_vector_db" {
  statement {
    sid     = "SSMRead"
    effect  = "Allow"
    actions = ["ssm:GetParameters"]
    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.env}/ai/vector-db/password",
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.env}/ai/vector-db/postgres-password",
    ]
  }

  statement {
    sid       = "KMSDecrypt"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [module.kms_app.key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
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
    resources = [module.kms_app.key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"]
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
  statement {
    sid       = "KMSForLogs"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [module.kms_app.key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"]
    }
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
    # CSI 소비자별 ServiceAccount를 신뢰 대상으로 지정한다.
    backend = {
      namespace           = "app"
      service_account     = "backend-sa"
      policy_json         = data.aws_iam_policy_document.backend.json
      create_policy       = true
      managed_policy_arns = []
    }
    ai = {
      namespace           = "ai"
      service_account     = "ai-worker-sa"
      policy_json         = data.aws_iam_policy_document.ai.json
      create_policy       = true
      managed_policy_arns = []
    }
    redis = {
      namespace           = "app"
      service_account     = "redis-sa"
      policy_json         = data.aws_iam_policy_document.redis.json
      create_policy       = true
      managed_policy_arns = []
    }
    ai-vector-db = {
      namespace           = "ai"
      service_account     = "ai-vector-db-sa"
      policy_json         = data.aws_iam_policy_document.ai_vector_db.json
      create_policy       = true
      managed_policy_arns = []
    }
    cnpg = {
      namespace           = "database"
      service_account     = "cnpg-backup-sa"
      policy_json         = data.aws_iam_policy_document.cnpg.json
      create_policy       = true
      managed_policy_arns = []
    }
    loki = {
      namespace           = "monitoring"
      service_account     = "loki-sa"
      policy_json         = data.aws_iam_policy_document.loki.json
      create_policy       = true
      managed_policy_arns = []
    }
    ebs-csi = {
      namespace           = "kube-system"
      service_account     = "ebs-csi-controller-sa"
      policy_json         = null
      create_policy       = false
      managed_policy_arns = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
    }
    alb-controller = {
      namespace           = "kube-system"
      service_account     = "aws-load-balancer-controller"
      policy_json         = null
      create_policy       = false
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
  create_policy       = each.value.create_policy
  managed_policy_arns = each.value.managed_policy_arns
  oidc_provider_arn   = module.eks.oidc_provider_arn
  oidc_provider_url   = module.eks.oidc_provider_url
}
