# ============================================================
# modules/eks_nodes/versions.tf
# ------------------------------------------------------------
# ⚠️ 모듈 안에 provider 블록은 두지 않습니다.
#    region·default_tags 는 루트(environments/*)가 갖고 모듈이 물려받습니다.
#    (검수 체크리스트 15)
# ============================================================

terraform {
  required_version = ">= 1.6"   # .tftest.hcl 은 1.6+ 필요

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
