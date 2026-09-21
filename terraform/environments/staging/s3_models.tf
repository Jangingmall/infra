# 공용 AI 모델 버킷은 Prod state에서만 생성·관리한다.
# Stage는 기존 버킷을 조회하므로 Stage destroy로 공용 버킷/정책을 삭제하지 않는다.
# Prod의 모델 버킷 생성 후 Stage plan/apply를 수행해야 한다.
data "aws_s3_bucket" "models" {
  bucket = "${var.project}-prod-s3-models"
}
