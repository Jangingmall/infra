# ============================================================
# modules/nat/locals.tf
# ============================================================

locals {
  # 모든 리소스 이름의 접두사 → "jangin-prod" / "jangin-staging"
  name = "${var.project}-${var.env}"

  # NAT 를 둘 Public 서브넷 ID.
  #
  # 왜 map 과 az_suffix 를 따로 받아 여기서 찾는가:
  #   루트에서 module.network.public_subnet_ids_by_az["z"] 처럼 없는 키를 쓰면
  #   Terraform 이 "Invalid index" 라는 불친절한 에러를 냅니다.
  #   lookup 의 기본값을 빈 문자열로 두고 main.tf 의 precondition 에서 잡으면
  #   "az_suffix 는 a 또는 c 여야 합니다" 라는 읽을 수 있는 에러가 납니다.
  #
  # lookup 은 키가 없어도 절대 에러를 내지 않는다는 점이 핵심입니다.
  nat_subnet_id = lookup(var.public_subnet_ids_by_az, var.az_suffix, "")
}
