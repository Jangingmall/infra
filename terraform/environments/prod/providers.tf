# ============================================================
# providers.tf — AWS provider 설정 + 공통 태그 일괄 적용
# ============================================================

provider "aws" {
  # 리전은 하드코딩하지 않고 변수로 (작업 규칙 4)
  region = var.region

  # default_tags = "이 provider로 만드는 모든 리소스에 이 태그를 자동으로 붙여라"
  #
  # 이게 없으면 리소스 19개마다 tags 블록을 똑같이 베껴 써야 하고,
  # 하나만 빠뜨려도 다정님 Cost Explorer 필터에서 그 리소스가 사라진다.
  #
  # 리소스에서 tags = { Name = ... } 를 쓰면 덮어쓰는 게 아니라
  # default_tags 와 "합쳐진다"(merge).
  default_tags {
    tags = local.common_tags
  }
}

# us-east-1 고정 provider — CloudFront용 ACM 인증서 전용 (modules/acm_cloudfront)
# CloudFront는 us-east-1에서 발급한 인증서만 붙일 수 있어 리전이 리소스 종류에 묶여 있음
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = local.common_tags
  }
}

# 🔴 NodePool 태그를 default_tags 에 넣지 않은 이유
#
#   NodePool 은 값이 system | app | db | ai 중 하나여야
#   Cost Explorer에서 "역할별 비용"을 가를 수 있다.
#   그런데 VPC·서브넷·IGW·라우팅 테이블은 그 어디에도 속하지 않는다.
#   억지로 NodePool = "network" 같은 값을 넣으면 다정님 필터
#   설계(4개 값)와 충돌해서 오히려 분석을 망친다.
#
#   → NodePool 은 ⑦ 노드그룹 단계에서 리소스별로 부여한다.
#
#   ⚠️ CLAUDE.md 검수 체크리스트 #9("NodePool 태그 있는가")와
#      문구가 어긋나므로 PR 본문에 이 근거를 적고 파트장 확인을 받는다.
#      (내 단독 결정 사항 아님)
