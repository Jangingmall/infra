locals {
  # Endpoint 이름 접두사 → "jangin-prod" / "jangin-staging"
  name = "${var.project}-${var.env}"
}
