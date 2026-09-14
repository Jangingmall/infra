# ============================================================
# locals.tf — 공통 태그
# ------------------------------------------------------------
# 🔄 2026-09-15 모듈 이관으로 줄어들었다.
#    data.aws_availability_zones 와 local.azs 는 그것을 쓰는
#    modules/network 로 옮겼다. (쓰는 곳 옆에 두는 것이 모듈 원칙)
#
#    여기 남은 것은 provider 의 default_tags 가 참조하는 common_tags 뿐이다.
#    provider 는 루트에만 선언하므로 태그도 루트에 있어야 한다.
# ============================================================

locals {
  # 리소스 이름 접두사. 모듈 밖에서 만드는 리소스가 생기면 쓴다.
  # (현재는 모듈이 각자 같은 식으로 조립한다)
  name = "${var.project}-${var.env}"

  # 모든 리소스에 자동으로 붙는 공통 태그 (providers.tf 의 default_tags)
  # 🔴 태그가 없으면 Cost Explorer 역할별 필터링이 안 된다.
  common_tags = {
    Project     = var.project
    Environment = var.env
    ManagedBy   = "Terraform"
    Owner       = "infra"
    # NodePool 은 의도적으로 제외 — providers.tf 주석 참고 (작업 규칙 13)
  }
}
