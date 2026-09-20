# ============================================================
# versions.tf
# ------------------------------------------------------------
# 🆕 tls provider 가 새로 필요합니다.
#    OIDC Provider 를 만들려면 EKS 발급자(issuer) 의 TLS 인증서 지문이 필요한데,
#    그 지문을 읽어오는 data source 가 tls provider 에 있습니다.
#    → 이 PR 이후 팀 전원이 terraform init 을 다시 돌려야 합니다.
# ============================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    tls = {
      source = "hashicorp/tls"
    }
  }
}
