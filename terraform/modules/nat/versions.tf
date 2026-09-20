# ============================================================
# modules/nat/versions.tf — 이 모듈이 쓰는 provider 선언
# ------------------------------------------------------------
# 모듈은 "혼자서도 말이 되는 단위"여야 하므로 required_providers 를 명시한다.
#
# ⚠️ 모듈 안에 provider "aws" { } 블록은 두지 않는다.
#    region · default_tags 같은 provider 설정은 루트(environments/*)가 갖고
#    모듈은 그것을 물려받는다. (검수 체크리스트 15)
# ============================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}
