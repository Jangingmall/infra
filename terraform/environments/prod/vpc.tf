# ============================================================
# vpc.tf — modules/network 호출 (IaC ②)   무료
# ------------------------------------------------------------
# 🔴 이 폴더(environments/prod)에는 리소스를 직접 선언하지 않는다.
#    "무엇을 만들지"는 modules/ 가 갖고,
#    "이 환경에서는 어떤 값으로 만들지"는 terraform.tfvars 가 갖는다.
#    그래야 staging 이 같은 모듈을 값만 바꿔 쓸 수 있다. (B안)
#
# 🔴 실행 순서를 depends_on 으로 강제하지 않는다.
#    security.tf / endpoints.tf 가 module.network.vpc_id 를 참조하는 것만으로
#    Terraform 이 "network 먼저"를 스스로 안다(암묵적 의존성).
#    depends_on 을 남발하면 병렬 실행이 막혀 apply 가 느려지고,
#    의존 관계가 코드에서 안 보인다.
#
# 🔄 2026-09-16: NAT 호출을 nat.tf 로 분리했다 (PR #19 파트장 리뷰 반영).
#    이 모듈이 만드는 것은 전부 요금이 $0 이라 작업 규칙 17 대상이 아니다.
# ============================================================

module "network" {
  source = "../../modules/network"

  project = var.project
  env     = var.env
  region  = var.region

  # ↓ 왼쪽(모듈 내부 이름)은 접두사 없음 / 오른쪽(루트 변수)은 vpc_ 접두사
  #   루트는 eks·alb·ecr 변수가 전부 한 파일(variables.tf)에 모이므로
  #   접두사가 없으면 "이게 누구 변수인지" 알 수 없어진다. (B안 컨벤션)
  vpc_cidr     = var.vpc_cidr
  az_suffixes  = var.vpc_az_suffixes
  subnet_cidrs = var.vpc_subnet_cidrs

  # 서브넷의 kubernetes.io/cluster/<이름> 태그에 쓰인다.
  # ⑥ EKS 단계에서 실제 생성할 클러스터 이름과 반드시 일치해야 한다.
  cluster_name = var.eks_cluster_name
}
