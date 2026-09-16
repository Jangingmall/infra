# ============================================================
# vpc.tf — VPC / 서브넷 6개 / IGW / 라우팅 테이블 3개 / 기본 SG 잠금
# ------------------------------------------------------------
# IaC 착수 순서 ② — 전부 무료 리소스
#
# 이번 범위 밖 (만들지 않음):
#   - NAT Gateway + EIP        → ⑤ nat.tf        (유료)
#   - Security Group 4종       → ③ security_group.tf
#   - S3 Gateway Endpoint      → ④ endpoints.tf
#   - VPC Flow Logs            → s3-logs 버킷(⑨) 선행 필요
# ============================================================


# ------------------------------------------------------------
# VPC — 우리만의 사설 네트워크 구획
# ------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # 이 둘은 EKS에서 사실상 필수다.
  # Pod가 서비스 이름(예: my-svc.default.svc)으로 서로를 찾고,
  # 노드가 EKS 엔드포인트 도메인을 해석해야 클러스터에 붙는다.
  # 꺼두면 노드가 NotReady 에서 멈추는데 원인이 잘 드러나지 않는다.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name}-vpc"
  }

  lifecycle {
    # 내가 고른 AZ(a, c)가 이 계정·리전에 실제로 존재하는지 검증한다.
    # 없으면 plan 단계에서 명확한 메시지로 멈춘다.
    #
    # 왜 여기에 넣었나: VPC는 나머지 전부의 뿌리라서, 여기서 막으면
    # 서브넷 생성 시점의 알아보기 힘든 AWS 에러를 미리 차단할 수 있다.
    #
    # (참고: terraform의 check 블록은 실패해도 "경고"만 내고 진행한다.
    #  precondition 은 plan을 실제로 실패시키므로 이쪽을 택했다.)
    precondition {
      condition = length(
        setsubtract(values(local.azs), data.aws_availability_zones.available.names)
      ) == 0
      error_message = "az_suffixes 로 만든 AZ가 이 리전에 없습니다. var.region 과 var.az_suffixes 를 확인하세요."
    }
  }
}


# ------------------------------------------------------------
# Internet Gateway — VPC와 인터넷을 잇는 문
# ------------------------------------------------------------
# IGW 자체는 무료다. 과금은 여기를 지나는 트래픽이 아니라
# NAT Gateway(⑤)와 공인 IPv4 주소에서 발생한다.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name}-igw"
  }
}


# ------------------------------------------------------------
# 서브넷 — 3계층(Public / Private App / Private Data) × 2 AZ = 6개
# ------------------------------------------------------------

# [1] Public — ALB가 앉는 자리. 인터넷에서 직접 닿는 유일한 계층.
resource "aws_subnet" "public" {
  # local.azs = { a = "ap-northeast-2a", c = "ap-northeast-2c" }
  # → 이 블록 하나가 서브넷 2개를 만든다. each.key = "a" / "c"
  for_each = local.azs

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_cidrs.public[each.key]
  availability_zone = each.value

  # 🔴 false 로 둔다.
  #   여기 뜨는 건 ALB뿐이고 ALB는 자기 공인 IP를 따로 받는다.
  #   자동 공인 IP를 켜두면 실수로 EC2를 띄웠을 때 인터넷에 바로
  #   노출되고, 공인 IPv4는 개당 시간 과금이다.
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name}-subnet-public-${each.key}"

    # 🔴 EKS ALB Controller가 "인터넷용 ALB를 어디에 만들지" 찾는 표식.
    #    없으면 Ingress를 만들어도 ALB가 생기지 않는데,
    #    에러가 컨트롤러 로그 깊은 곳에만 남아 원인 찾기가 어렵다.
    "kubernetes.io/role/elb" = "1"

    # 이 서브넷이 어느 클러스터 소속인지. VPC에 클러스터가 1개면
    # 없어도 자동 탐색되지만, 나중에 누락 사고를 막기 위해 미리 넣는다.
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# [2] Private App — EKS 노드와 Pod가 사는 자리.
resource "aws_subnet" "app" {
  for_each = local.azs

  vpc_id     = aws_vpc.main.id
  cidr_block = var.subnet_cidrs.app[each.key] # 🔴 /20 (10.0.16.0/20, 10.0.32.0/20)

  availability_zone = each.value

  tags = {
    Name = "${local.name}-subnet-app-${each.key}"

    # 내부용 LB 배치 표식 (외부 공개 없는 서비스용)
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# [3] Private Data — CloudNativePG(DB) Pod가 사는 자리.
resource "aws_subnet" "data" {
  for_each = local.azs

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_cidrs.data[each.key]
  availability_zone = each.value

  # EKS 태그를 붙이지 않는다 — LB가 앉을 계층이 아니기 때문이다.
  # 태그를 붙이면 ALB Controller가 DB 계층에 LB를 만들 수 있게 된다.
  tags = {
    Name = "${local.name}-subnet-data-${each.key}"
  }
}


# ------------------------------------------------------------
# 라우팅 테이블 — "이 서브넷의 트래픽은 어디로 보내나"
# ------------------------------------------------------------
#
# ⚠️ 초보가 가장 자주 빠뜨리는 부분:
#    서브넷을 어떤 라우팅 테이블에도 연결하지 않으면, AWS는 그 서브넷을
#    VPC의 "기본(main) 라우팅 테이블"에 자동으로 묶는다.
#    나중에 누군가 main 테이블에 0.0.0.0/0 을 추가하면
#    → data 계층이 조용히 인터넷에 연결된다 (보안팀 NAT 조건 #2 위반).
#    그래서 계층마다 전용 테이블을 만들고 명시적으로 묶는다.

# [public] 인터넷으로 나가는 경로가 있는 유일한 테이블
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name}-rt-public"
  }
}

resource "aws_route" "public_igw" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0" # 목적지를 모르는 모든 트래픽
  gateway_id             = aws_internet_gateway.main.id
}

# [app] 지금은 경로가 비어 있다(=VPC 내부 통신만 가능).
#       ⑤ nat.tf 에서 0.0.0.0/0 → NAT Gateway 경로를 여기에 추가한다.
#
#       테이블이 1개인 이유: NAT GW를 AZ-a 단일로 쓰기로 확정했으므로
#       app-a / app-c 가 같은 NAT를 바라본다.
#       멀티 AZ NAT로 가면 AZ별로 테이블을 쪼개야 한다.
resource "aws_route_table" "app" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name}-rt-app"
  }
}

# [data] 🔴 0.0.0.0/0 경로를 "영구히" 만들지 않는다 (작업 규칙 7).
#        DB 계층은 인터넷으로 나갈 수도, 인터넷에서 들어올 수도 없다.
#        S3 백업은 ④ S3 Gateway Endpoint 를 이 테이블에 붙여서 처리한다
#        (NAT를 안 거치므로 무료).
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name}-rt-data"
  }
}


# ------------------------------------------------------------
# 서브넷 ↔ 라우팅 테이블 연결 (6개)
# ------------------------------------------------------------
resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "app" {
  for_each = aws_subnet.app

  subnet_id      = each.value.id
  route_table_id = aws_route_table.app.id
}

resource "aws_route_table_association" "data" {
  for_each = aws_subnet.data

  subnet_id      = each.value.id
  route_table_id = aws_route_table.data.id
}


# ------------------------------------------------------------
# 기본 보안그룹 잠금 — "AWS가 만든 것을 비우는" 리소스
# ------------------------------------------------------------
#
# AWS는 VPC를 만들면 default 라는 SG를 자동으로 끼워 넣는다.
# 그 기본값이
#   inbound : 같은 SG를 가진 리소스끼리 "모든 포트" 허용
#   outbound: 전체 허용
# 이라서, 우리가 만들지 않았는데 열려 있는 SG가 남는다.
# → CIS 벤치마크 지적 항목이고 9/18 보안팀 스캔에 걸린다.
#
# ③ security_group.tf 와 성격이 다르다:
#   ③ = 우리가 새로 "만드는" SG 4종
#   이것 = AWS가 이미 만든 것을 "잠그는" 작업
#
# ⚠️ 처음 보면 헷갈리는 2가지
#   1. resource 라고 쓰여 있지만 SG를 새로 만들지 않는다.
#      기존 default SG를 terraform 관리로 가져와(입양) 규칙을 비운다.
#      그래서 plan에 "1 to add" 로 표시되지만 실제 생기는 SG는 없다.
#   2. terraform destroy 해도 default SG는 삭제되지 않는다
#      (AWS가 삭제를 금지). terraform이 관리를 그만둘 뿐이고,
#      규칙이 비워진 상태는 그대로 남는다.
resource "aws_default_security_group" "locked" {
  vpc_id = aws_vpc.main.id

  # ingress / egress 블록을 하나도 쓰지 않는다 → 모든 규칙이 제거된다.
  # (검수 체크리스트 #5 위반 아님 — 규칙이 0개이므로 cidr_blocks 자체가 없다)

  tags = {
    Name = "${local.name}-sg-default-locked"
  }
}
