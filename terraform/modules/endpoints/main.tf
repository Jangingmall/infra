# ============================================================
# endpoints.tf — S3 Gateway Endpoint 1개 + 라우팅 테이블 연결 2개
# ------------------------------------------------------------
# IaC 착수 순서 ④ — 전부 무료 리소스
#
# 이 파일이 하는 일을 한 줄로:
#   ③ security_group.tf 가 발급해둔 "S3로 나가도 좋다"는 통행증에,
#   실제로 지나갈 도로를 놓는다.
#
#   SG            = 통행 허가증 — 이 패킷이 나가도 되는가?
#   라우팅 테이블  = 실제 도로   — 나간다면 어느 문으로 가는가?
#   🔴 둘 다 있어야 통신이 된다. 하나만 있으면 "조용히" 실패한다.
#
# 이번 범위 밖 (만들지 않음):
#   - ECR Interface Endpoint   → 미도입 확정
#     (NAT 처리료 $2.95  vs  Interface Endpoint $10.28 — 비용 비교 결과)
#   - NAT Gateway + EIP        → ⑤ nat.tf        (유료)
#   - S3 버킷 5종 · 버킷 정책   → ⑨
#   - Endpoint Policy          → ⑨ (아래 TODO 참고)
#
# ✅ 선행조건 확인 완료:
#    Gateway Endpoint는 VPC의 enable_dns_support = true 를 요구한다.
#    vpc.tf 에서 이미 켜져 있다 (EKS 때문에 어차피 필수였다).
#
# ------------------------------------------------------------
# 🔵 Gateway Endpoint 와 Interface Endpoint 의 차이
# ------------------------------------------------------------
#                   Gateway                     Interface
#   정체          라우팅 테이블에 꽂히는        내 서브넷 안에 생기는
#                 "지름길 표지판"                "AWS 대리점 창구"(ENI)
#   실체          물리 장비 없음. 경로 1줄      사설 IP를 가진 ENI가 실제로 생김
#   SG 부착       ❌ 불가 (붙일 ENI가 없음)     ⭕ 가능
#   비용          $0 (시간·처리량 모두 무료)    시간당 + 처리 요금
#   지원 서비스   S3, DynamoDB 딱 2개           그 외 대부분(ECR·STS·SSM·KMS…)
#
#   👉 "S3를 왜 Gateway로 하나"는 선택의 문제가 아니다.
#      S3는 AWS가 Gateway를 제공하는 2개 서비스 중 하나이고, 무료다.
#      반대로 ECR은 Gateway가 없어 Interface뿐이라 유료였고,
#      계산해보니 NAT보다 비싸서 안 만들기로 확정했다.
#      → 정리하면 "무료면 쓰고(S3), 유료면 NAT와 비교해서 판단(ECR)".
#
# ⚠️ 흔한 오해: "Endpoint를 만들면 S3 통신이 사설망으로 바뀐다" → 절반만 맞다.
#    도메인도 IP도 여전히 S3의 공인 주소다.
#    바뀌는 건 패킷이 나가는 "문"뿐이다 (NAT/IGW → VPC 내부 지름길).
#    그래서 ③의 아웃바운드 SG 규칙이 여전히 필요하다.
# ============================================================


# ------------------------------------------------------------
# S3 Gateway Endpoint 본체
# ------------------------------------------------------------
resource "aws_vpc_endpoint" "s3" {
  vpc_id = var.vpc_id

  # "com.amazonaws.ap-northeast-2.s3"
  # 🔴 리전을 하드코딩하지 않는다 (작업 규칙 4).
  #    security_group.tf 의 prefix list 조회와 완전히 같은 패턴이다.
  service_name = "com.amazonaws.${var.region}.s3"

  # provider 기본값이 "Gateway" 라 생략해도 동작하지만 명시한다.
  # 이 한 줄이 "여긴 무료다 / ENI가 없다 / SG를 못 붙인다" 를 동시에 알려준다.
  vpc_endpoint_type = "Gateway"

  # 🔴 route_table_ids 인라인 인자를 "쓰지 않는다".
  #
  #    이 리소스에는 route_table_ids = [...] 를 직접 쓰는 방법도 있다.
  #    하지만 아래 aws_vpc_endpoint_route_table_association 과 섞으면
  #    apply 할 때마다 서로의 연결을 지웠다 만들었다 반복한다.
  #    (security_group.tf 의 "인라인 블록 + 분리 리소스 혼용 금지" 와
  #     정확히 같은 함정이다)
  #    → 이 환경은 분리 리소스 스타일로 통일한다.

  # TODO(⑨ S3 버킷 단계) — Endpoint Policy 를 붙인다.
  #
  #   policy 를 생략하면 AWS 기본값이 "모든 S3 버킷 Full Access" 다.
  #   즉 app·data 서브넷의 무엇이든 "우리 것이 아닌 제3자 버킷"에도
  #   이 무료 경로로 접근할 수 있다 = 데이터 유출 경로.
  #
  #   🔴 이건 모르고 넘어가는 게 아니라 "인지한 잔여위험" 이다.
  #      지금 제한하려면 버킷 ARN이 필요한데 버킷은 ⑨에서 만든다.
  #      ⑨에서 s3-images/returns/backup/models/logs 5종으로 좁힌다.
  #      (그때도 계정 ID 하드코딩 금지 — data.aws_caller_identity 사용)

  tags = {
    Name = "${local.name}-vpce-s3"
  }
}


# ------------------------------------------------------------
# 라우팅 테이블 연결 — app / data 2개
# ------------------------------------------------------------
#
# 🔵 이 리소스가 라우팅 테이블에 무엇을 추가하나
#
#   [ 연결 전 rt-data ]
#     10.0.0.0/16   → local            (VPC 생성 시 자동, 삭제 불가)
#
#   [ 연결 후 rt-data ]
#     10.0.0.0/16   → local
#     pl-xxxxxxxx   → vpce-xxxxxxxx    ← AWS가 자동으로 꽂아준다
#
# 🔴 초보가 헷갈리는 지점: 이 경로는 aws_route 리소스로 만들지 않는다.
#    association 을 만들면 AWS가 알아서 경로 항목을 삽입한다.
#    aws_route 로 따로 만들려고 하면 실패한다.
#
# 🔵 목적지가 CIDR이 아니라 pl- 인 이유
#    S3의 IP 대역은 AWS가 수시로 바꾼다. prefix list 는 "지금 이 리전
#    S3의 IP 목록"을 ID 하나로 묶은 것이라, AWS가 목록을 갱신하면
#    우리 경로가 자동으로 따라간다.
#    → security_group.tf 의 data.aws_ec2_managed_prefix_list.s3 와 같은 물건이다.
#      SG 규칙의 목적지도 pl-xxx, 라우팅의 목적지도 pl-xxx 라서
#      두 통제가 정확히 같은 IP 집합을 가리킨다.
#
# 🔵 ⑤ NAT를 붙인 뒤에도 S3가 NAT로 새지 않는 이유 (비용 핵심)
#    rt-app 에는 곧 0.0.0.0/0 → NAT GW 가 추가된다. 그래도 S3는 NAT로 안 간다.
#    라우팅은 longest prefix match(더 구체적인 경로 우선)로 동작하고,
#    prefix list 경로는 0.0.0.0/0 보다 항상 구체적이기 때문이다.
#    → ECR 이미지 레이어(S3에 저장됨)·Loki 청크·AI 모델 가중치가
#      NAT 처리료($0.059/GB)를 타지 않는다.
#
# 🔵 data 계층이 0.0.0.0/0 없이도 S3에 닿는 원리 (보안팀 NAT 조건 #2)
#    rt-data 에는 인터넷 경로가 없고 이 pl- 경로만 있다.
#      목적지가 S3        → pl 에 매칭 → vpce 로 나감 → 도착 ✅
#      목적지가 그 외 인터넷 → 매칭되는 경로 없음 → 폐기 ❌
#    "인터넷 전체를 여는 문"이 아니라 "S3만 가는 전용 문"을 낸 것이다.
#    보안팀 검증도 간단하다 — rt-data 에 0.0.0.0/0 이 있는지만 보면 된다.
#
# ⚠️ 그래도 남는 문제 — ④로는 해결할 수 없다.
#    이 Endpoint는 ECR "이미지 레이어"(S3에 저장된 부분)만 덮는다.
#    ECR API 인증(ecr.api / ecr.dkr)과 STS는 못 덮는다.
#    → DB 노드그룹을 data 서브넷에 두면 이미지 pull 이 실패한다.
#      security_group.tf 의 db_out_all 주석에 적어둔 미해결 사안 그대로이고,
#      ⑦ 노드그룹 착수 전 파트장(강윤주) 확인이 필요하다.

resource "aws_vpc_endpoint_route_table_association" "s3" {
  # 🔴 여기에 public 이 없다는 사실 자체가 설계 문서다.
  #
  #    rt-public 에 붙이지 않는 이유:
  #      1. public 서브넷엔 ALB만 있고, ALB는 AWS 관리형이라
  #         우리 라우팅 테이블을 타고 S3에 가지 않는다
  #         (액세스 로그는 AWS 서비스가 직접 전달한다).
  #      2. public 은 IGW로 직행하는데, 동일 리전 S3행 트래픽은
  #         IGW 경유라도 원래 무료다 → 비용 이득도 0.
  #    → 붙일 이유가 하나도 없다.
  for_each = var.route_table_ids

  vpc_endpoint_id = aws_vpc_endpoint.s3.id
  route_table_id  = each.value
}
