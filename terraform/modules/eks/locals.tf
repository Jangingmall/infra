locals {
  # 리소스 이름 접두사 → "jangin-prod" / "jangin-staging"
  name = "${var.project}-${var.env}"
}
