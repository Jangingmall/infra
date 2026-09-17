# ============================================================
# modules/eks/main.tf — EKS 클러스터 + OIDC Provider (IaC ⑥)   💰 유료
# ------------------------------------------------------------
# 무엇을 만드는가 (쉽게):
#   ① 컨트롤플레인용 IAM 역할 — AWS 가 우리 계정 안에서 ENI·ELB 등을 다룰 권한
#   ② CloudWatch 로그 그룹 — 컨트롤플레인 감사 로그가 쌓일 곳
#   ③ EKS 클러스터 본체 — "관제탑". 노드는 ⑦ 에서 붙입니다
#   ④ OIDC Provider — 클러스터가 발급한 Pod 신분증을 AWS 가 믿게 만드는 장치 (IRSA 전제조건)
#
# 💰 EKS 컨트롤플레인은 시간당 요금이 붙고 **끌 수 없습니다.**
#    노드를 다 내려도 클러스터가 있으면 과금됩니다 (비용 산정서 상시 408h 항목).
#    작업 규칙 17 — 9/17 까지 plan 까지만, apply 는 9/18 일괄.
# ============================================================


# ------------------------------------------------------------
# ① 컨트롤플레인 IAM 역할
# ------------------------------------------------------------
# "AWS 의 EKS 서비스가 우리 계정에서 대신 일할 수 있게" 해주는 역할입니다.
# 예: 컨트롤플레인 ENI 를 우리 서브넷에 꽂는 일.
data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.name}-iam-role-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json

  tags = {
    Name = "${local.name}-iam-role-eks-cluster"
  }
}

# ⚠️ 아래 ARN 의 계정 자리가 "aws" 인 것은 AWS 가 소유한 관리형 정책이라는 뜻입니다.
#    우리 계정 ID 하드코딩이 아니므로 검수 체크리스트 #8 위반이 아닙니다.
resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    # ↓ Pod 단위 SG(Security Groups for Pods) 를 쓰려면 필요합니다.
    #   지금 쓰지 않더라도 나중에 붙이려면 클러스터 재생성이 아니라 정책 추가로 끝나므로
    #   미리 넣어 둡니다.
    "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController",
  ])

  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}


# ------------------------------------------------------------
# ② CloudWatch 로그 그룹 — 🔴 클러스터보다 먼저 만듭니다
# ------------------------------------------------------------
# 왜 먼저 만드는가:
#   enabled_cluster_log_types 를 켜면 EKS 가 /aws/eks/<이름>/cluster 로그 그룹을
#   **자기가 알아서 만듭니다.** 그런데 그때 보관 기간이 "무제한(Never expire)" 입니다.
#   프로젝트가 끝나고 클러스터를 지워도 로그는 남아서 요금이 계속 나갑니다.
#
#   그래서 Terraform 이 보관 기간을 지정해 먼저 만들어 두고, 클러스터가 그걸 쓰게 합니다.
#   실무에서 놓치기 쉬운데 비용으로 바로 이어지는 항목입니다.
resource "aws_cloudwatch_log_group" "cluster" {
  count = length(var.enabled_cluster_log_types) > 0 ? 1 : 0

  # 🔴 이 이름은 EKS 가 정한 고정 규칙입니다. 바꾸면 클러스터가 다른 곳에 또 만듭니다.
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${local.name}-log-eks-cluster"
  }
}


# ------------------------------------------------------------
# ③ EKS 클러스터
# ------------------------------------------------------------
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    # 컨트롤플레인 ENI 가 꽂힐 서브넷. app(private) 서브넷을 넣습니다.
    subnet_ids = var.subnet_ids

    # 🔴 "공개"라도 인증 명부에 없으면 401 입니다.
    #    여기서 정하는 건 전화선 연결 여부이지 문이 열려 있는지가 아닙니다.
    endpoint_public_access = var.endpoint_public_access
    public_access_cidrs    = var.public_access_cidrs

    # 노드 ↔ 컨트롤플레인 통신을 VPC 내부 경로로 보내 안정성을 높입니다.
    endpoint_private_access = var.endpoint_private_access

    # 보통 비워 둡니다. EKS 가 eks-cluster-sg-<이름> 을 자동 생성해
    # 컨트롤플레인 ↔ 노드 간 통신을 스스로 엽니다.
    security_group_ids = var.additional_security_group_ids
  }

  access_config {
    authentication_mode                         = var.authentication_mode
    bootstrap_cluster_creator_admin_permissions = var.bootstrap_cluster_creator_admin_permissions
  }

  enabled_cluster_log_types = var.enabled_cluster_log_types

  # Secret 봉투 암호화. ⑧ KMS 단계에서 값이 들어옵니다.
  # 🔴 클러스터 생성 후 "추가"는 되지만 "해제"는 안 됩니다.
  dynamic "encryption_config" {
    for_each = var.secrets_kms_key_arn == null ? [] : [1]

    content {
      resources = ["secrets"]

      provider {
        key_arn = var.secrets_kms_key_arn
      }
    }
  }

  tags = {
    Name = var.cluster_name
  }

  # ⚠️ depends_on 을 쓰는 두 번째·세 번째 정당한 자리입니다.
  #    (첫 번째는 modules/network 의 NAT → IGW)
  #    둘 다 "코드에서 참조하지 않는데 먼저 있어야 하는" 표현 불가 의존성입니다.
  #      - 정책 연결이 늦으면 클러스터 생성이 권한 부족으로 실패합니다
  #      - 로그 그룹이 늦으면 EKS 가 보관 기간 무제한으로 먼저 만들어버립니다
  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]

  lifecycle {
    precondition {
      condition     = length(var.subnet_ids) >= 2
      error_message = "EKS 는 서로 다른 AZ 의 서브넷이 2개 이상 필요합니다. app 서브넷 2개(a/c)를 넘기세요."
    }

    precondition {
      condition     = var.endpoint_public_access || var.endpoint_private_access
      error_message = "public·private 접근을 둘 다 끄면 아무도 클러스터에 접속할 수 없습니다."
    }

    # 🔴 2026-09-17 신설 — 실수로 전 세계에 열리는 것을 막는 안전장치
    #
    #    팀 결정(B안)은 "구축 기간에는 public 을 열되 팀원 IP 로 제한" 입니다.
    #    그런데 public 을 켠 채 CIDR 을 빠뜨리면 AWS 가 0.0.0.0/0 으로 간주합니다.
    #    → 에러도 경고도 없이 전 세계에서 접근 가능한 상태가 됩니다.
    #
    #    ⚠️ 정말 전체를 열어야 하는 상황이면 이 블록을 지우는 PR 을 올립니다.
    #       "열려면 리뷰를 거쳐라" 가 이 장치의 목적입니다.
    precondition {
      condition = (
        !var.endpoint_public_access
        || (length(var.public_access_cidrs) > 0 && !contains(var.public_access_cidrs, "0.0.0.0/0"))
      )
      error_message = "endpoint_public_access = true 이면 public_access_cidrs 에 팀원 IP 를 지정해야 합니다. 빈 목록이거나 0.0.0.0/0 은 허용하지 않습니다 (2026-09-17 팀 결정 B안)."
    }
  }
}


# ------------------------------------------------------------
# ④ OIDC Provider — IRSA 전제조건
# ------------------------------------------------------------
# 무엇인가 (쉽게):
#   Pod 가 AWS 자원(S3·Parameter Store 등)을 쓰려면 신분증이 필요합니다.
#   클러스터는 Pod 에게 "이 Pod 는 app 네임스페이스의 backend-sa 다" 라는 토큰을 발급합니다.
#   그런데 AWS 입장에서는 그 토큰을 발급한 클러스터를 모릅니다.
#   OIDC Provider 는 **"이 발급기관을 믿겠다"고 AWS 에 등록**하는 절차입니다.
#
# 🔴 이게 없으면 IRSA 6종이 전부 동작하지 않고,
#    에러가 sts:AssumeRoleWithWebIdentity 실패로만 나와 원인이 잘 드러나지 않습니다.
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer

  # 이 발급기관이 만든 토큰을 "누구에게 쓰라고" 발급했는지.
  # IRSA 는 항상 sts.amazonaws.com 입니다.
  client_id_list = ["sts.amazonaws.com"]

  # 발급기관 TLS 인증서의 지문. AWS 가 위조된 발급기관을 걸러내는 장치입니다.
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]

  tags = {
    Name = "${local.name}-oidc-eks"
  }
}
