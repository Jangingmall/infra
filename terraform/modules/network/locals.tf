# ============================================================
# modules/network/locals.tf — 이름·AZ 목록 조립 + AZ 실존 검증용 data
# ------------------------------------------------------------
# 🔄 2026-09-15 모듈 이관: environments/prod/locals.tf 에 있던
#    data.aws_availability_zones 와 local.azs 를 이 모듈로 옮겼다.
#    이유: 이 둘을 쓰는 곳(aws_vpc 의 precondition, 서브넷 for_each)이
#    전부 이 모듈 안에 있기 때문. 쓰는 곳 옆에 두는 것이 모듈 원칙이다.
#
# ⚠️ common_tags 는 여기로 옮기지 않는다.
#    provider 의 default_tags 로 붙기 때문에 모듈은 태그를 몰라도 된다.
#    (모듈 안에서 provider 를 선언하지 않는 것도 같은 이유 — 루트가 넘겨준다)
# ============================================================

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # 모든 리소스 이름의 접두사 → "jangin-prod" / "jangin-staging"
  name = "${var.project}-${var.env}"

  # AZ 접미사 → 실제 AZ 이름 map
  #   { a = "ap-northeast-2a", c = "ap-northeast-2c" }
  azs = { for s in var.az_suffixes : s => "${var.region}${s}" }
}
