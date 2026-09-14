# ============================================================
# main.tf — 모듈 호출만 한다
# ------------------------------------------------------------
# 🔴 이 폴더(environments/prod)에는 리소스를 직접 선언하지 않는다.
#    "무엇을 만들지"는 modules/ 가 갖고,
#    "이 환경에서는 어떤 값으로 만들지"는 terraform.tfvars 가 갖는다.
#    그래야 staging 이 같은 모듈을 값만 바꿔 쓸 수 있다.
#
# 🔴 모듈 간 연결은 반드시 "A 의 output → B 의 variable" 로 한다.
#    modules/security 안에서 aws_vpc.main.id 를 직접 쓰면
#    그 모듈은 네트워크 모듈 없이는 못 쓰는 물건이 된다.
#
# 🔴 실행 순서를 depends_on 으로 강제하지 않는다.
#    module.network.vpc_id 를 참조하는 것만으로 Terraform 이
#    "network 먼저"를 스스로 안다(암묵적 의존성). depends_on 을 남발하면
#    병렬 실행이 막혀 apply 가 느려지고, 의존 관계가 코드에서 안 보인다.
# ============================================================

# ------------------------------------------------------------
# ② VPC · 서브넷 6개 · 라우팅 · IGW · 기본 SG 잠금   [배포 완료]
# ------------------------------------------------------------
module "network" {
  source = "../../modules/network"

  project      = var.project
  env          = var.env
  region       = var.region
  vpc_cidr     = var.vpc_cidr
  az_suffixes  = var.az_suffixes
  subnet_cidrs = var.subnet_cidrs
  cluster_name = var.cluster_name
}

# ------------------------------------------------------------
# ③ Security Group 4종 + 규칙 15개                   [배포 완료]
# ------------------------------------------------------------
module "security" {
  source = "../../modules/security"

  project = var.project
  env     = var.env
  region  = var.region

  # ↓ 여기가 모듈 간 연결선. network 가 먼저 만들어져야 함을
  #   Terraform 이 이 참조 한 줄로 알아낸다.
  vpc_id = module.network.vpc_id
}

# ------------------------------------------------------------
# ④ S3 Gateway Endpoint (무료)                        [배포 완료]
# ------------------------------------------------------------
module "endpoints" {
  source = "../../modules/endpoints"

  project = var.project
  env     = var.env
  region  = var.region

  vpc_id = module.network.vpc_id

  # app · data 라우팅 테이블에만 연결한다. public 은 넣지 않는다.
  # (이유는 modules/endpoints/variables.tf 주석 참고)
  route_table_ids = module.network.route_table_ids_for_s3_endpoint
}

# ------------------------------------------------------------
# ⑤ NAT Gateway  ⑥ EKS  ⑦ 노드그룹  ⑧ KMS·IRSA
#    💰 과금 리소스 — 작업 규칙 17에 따라 9/18 일괄 apply
#    코드는 별도 PR 에서 추가한다.
# ------------------------------------------------------------
