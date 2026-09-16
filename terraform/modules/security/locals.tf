locals {
  # 모든 SG 이름의 접두사 → "jangin-prod" / "jangin-staging"
  name = "${var.project}-${var.env}"
}
