# ============================================================
# versions.tf — 이 모듈이 어떤 provider 를 쓰는지 선언
# ------------------------------------------------------------
# 없어도 Terraform 이 aws_ 접두사를 보고 hashicorp/aws 로 추측하지만,
# 명시하지 않으면 다른 네임스페이스의 동명 provider 로 잘못 붙을 수 있다.
# 모듈은 "혼자서도 말이 되는 단위"여야 하므로 선언해 둔다.
#
# ⚠️ 모듈 안에 provider "aws" { } 블록은 두지 않는다.
#    provider 설정(region · default_tags)은 루트(environments/*)가 갖고
#    모듈은 그것을 물려받는다. 모듈이 자기 provider 를 가지면
#    환경마다 다른 리전을 쓸 수 없게 된다.
# ============================================================

terraform {
  required_version = ">= 1.5" # moved 블록은 1.1+, 이 레포 기준 1.5+

  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}
