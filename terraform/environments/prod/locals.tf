# ============================================================
# locals.tf — 이름·태그·AZ 목록 조립
# ------------------------------------------------------------
# 역할: 여러 파일에서 반복되는 계산을 한 곳에 모은다.
#       variable = "밖에서 넣는 값" / local = "안에서 만든 값"
# ============================================================

# 이 계정·리전에서 실제로 쓸 수 있는 AZ 목록을 AWS에 물어본다.
# 아래 lifecycle precondition 에서 "내가 고른 AZ가 진짜 있는지"
# 검증하는 데 쓴다.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # 모든 리소스 이름의 접두사 → "jangin-prod"
  # 환경 세그먼트가 앞쪽에 있어야 IAM 정책에서 jangin-prod-* 로 자를 수 있다.
  name = "${var.project}-${var.env}"

  # AZ 접미사 → 실제 AZ 이름 map
  #   { a = "ap-northeast-2a", c = "ap-northeast-2c" }
  #
  # map으로 만드는 이유: 아래 서브넷들이 for_each 로 이걸 돌면서
  # each.key("a") 는 이름에, each.value("ap-northeast-2a") 는
  # availability_zone 인자에 쓴다. 한 번의 순회로 둘 다 얻는다.
  azs = { for s in var.az_suffixes : s => "${var.region}${s}" }

  # 모든 리소스에 자동으로 붙는 공통 태그 (providers.tf 의 default_tags)
  # 🔴 태그가 없으면 Cost Explorer 역할별 필터링이 안 된다.
  common_tags = {
    Project     = var.project
    Environment = var.env
    ManagedBy   = "Terraform"
    Owner       = "infra"
    # NodePool 은 의도적으로 제외 — providers.tf 주석 참고
  }
}
