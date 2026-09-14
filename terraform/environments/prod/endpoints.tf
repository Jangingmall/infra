# ============================================================
# endpoints.tf — modules/endpoints 호출 (IaC ④)
# ------------------------------------------------------------
# S3 Gateway Endpoint. 라우팅 테이블에 경로 한 줄을 추가하는 방식이라
# 시간당 요금이 없다(무료). Interface Endpoint(ENI 방식)와 다르다.
# ============================================================

module "endpoints" {
  source = "../../modules/endpoints"

  project = var.project
  env     = var.env
  region  = var.region

  vpc_id = module.network.vpc_id

  # app · data 라우팅 테이블에만 연결한다. public 은 넣지 않는다.
  #   1. public 에는 ALB 만 있고 ALB 는 AWS 관리형이라
  #      우리 라우팅 테이블을 타고 S3 에 가지 않는다.
  #   2. public 은 IGW 직행인데 동일 리전 S3행은 IGW 경유라도 무료다.
  #   → 붙일 이유가 없다. (근거는 modules/endpoints/variables.tf 주석)
  route_table_ids = module.network.route_table_ids_for_s3_endpoint
}
