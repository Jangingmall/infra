# ============================================================
# security_group.tf — Security Group 4종 + 규칙 15개
# ------------------------------------------------------------
# IaC 착수 순서 ③ — 전부 무료 리소스
#
# 이번 범위 밖 (만들지 않음):
#   - NAT Gateway + EIP        → ⑤ nat.tf
#   - S3 Gateway Endpoint 리소스 → ④ endpoints.tf
#     (여기서는 Endpoint로 나가는 트래픽을 "허용"만 한다.
#      Endpoint 자체는 ④에서 만든다 — 허용과 길은 별개다)
#   - VPC Flow Logs            → s3-logs 버킷(⑨) 선행 필요
#
# ------------------------------------------------------------
# 🔴 설계 1 — 왜 "빈 껍데기 SG + 규칙 분리" 인가 (순환 참조 회피)
# ------------------------------------------------------------
# SG를 만들 때 ingress/egress 를 블록 안에 같이 쓰면 이렇게 된다.
#
#   sg-alb      ──(egress 8080 대상 = sg-eks-node)──▶ sg-eks-node
#   sg-eks-node ──(ingress 8080 출처 = sg-alb)─────▶ sg-alb
#   → Error: Cycle: ...
#
# terraform은 "무엇을 먼저 만들지"를 의존 그래프로 정한다.
# 위 상태는 둘이 서로를 가리켜서 순서를 못 정한다.
# (문 앞에서 두 사람이 "네가 먼저 들어와" 하며 굳어버리는 상황)
#
# 그래서 이 파일은 이렇게 쪼갠다.
#   [1단계] SG 4개를 "규칙 0개인 빈 껍데기"로 만든다 → 서로를 모르므로 동시 생성 가능
#   [2단계] 규칙을 별도 리소스로 만들어 양쪽 id를 참조 → 껍데기가 다 생긴 뒤라 순환 없음
#
# ⚠️ 인라인 블록과 분리 리소스를 "섞지" 말 것.
#    섞으면 terraform이 apply 할 때마다 서로의 규칙을 지웠다 만들었다 반복한다.
#
# ⚠️ 구형 aws_security_group_rule 이 아니라 신형(provider 5.x)
#    aws_vpc_security_group_ingress_rule / _egress_rule 을 쓴다.
#    규칙마다 AWS 쪽 고유 ID가 생겨서, 설명만 고쳐도 엉뚱한 규칙이
#    지워지는 구형의 고질병이 없다.
#
# ⚠️ 신형 리소스는 규칙 1개당 출처(또는 대상) 1개만 허용한다.
#    cidr_ipv4 / referenced_security_group_id / prefix_list_id 중 택 1.
#    그래서 443과 80이 한 블록이 아니라 각각 별도 리소스다.
#
# ------------------------------------------------------------
# 🔴 설계 2 — 표에 있지만 "만들지 않는 것" 5종 (안 만든 것도 설계다)
# ------------------------------------------------------------
#  1. sg-alb 의 9090  (인바운드·아웃바운드 어느 쪽도 없음)
#     → Spring 관리 포트다. ALB에 열면 /actuator/prometheus 가 인터넷에
#       노출되고, 거기엔 내부 엔드포인트 목록·JVM 정보·환경변수 키가
#       들어 있어 공격자에겐 지도나 다름없다.
#       (작업 규칙 6 · 검수 체크리스트 #4)
#
#  2. sg-eks-gpu → sg-db 5432
#     → GPU Pod가 DB를 직접 볼 이유가 없다. AI 쪽에 DB 접근이 필요해지면
#       반드시 App을 경유한다. GPU 컨테이너는 외부 이미지 비중이 높아
#       뚫렸을 때 DB까지 직행하는 경로를 애초에 만들지 않는다.
#       (작업 규칙 8 · 검수 체크리스트 #6)
#
#  3. sg-nat
#     → NAT Gateway는 AWS 관리형이라 SG를 붙일 수 없다. NAT 통제는
#       SG가 아니라 라우팅 테이블과 NACL로 한다. (09-09판 설계의 잔재)
#
#  4. sg-alb 의 아웃바운드 443 (인터넷 방향)
#     → ALB가 스스로 외부로 나갈 일이 없다. 확정 표에도 없다.
#
#  5. 노드 ↔ 노드 전체 허용 (self all traffic)
#     → EKS 클러스터를 만들면 AWS가 eks-cluster-sg-* 를 자동 생성해
#       노드 ENI에 함께 붙인다. 클러스터 내부 통신과 컨트롤플레인↔노드는
#       그쪽이 담당한다.
#       🔴 ⑥ 단계에서 "Pod 통신이 안 된다"고 당황해서 여기에
#          self all-traffic 을 추가하지 말 것. 최소권한이 깨진다.
# ============================================================


# ------------------------------------------------------------
# S3 Managed Prefix List 조회
# ------------------------------------------------------------
# Prefix List가 뭔가:
#   S3는 AWS가 운영하는 서비스라 IP 대역이 수시로 바뀐다.
#   그래서 AWS가 "지금 이 리전 S3의 IP 목록"을 pl-xxxxxxxx 라는
#   ID 하나로 묶어 제공한다. SG 규칙에 이 ID를 넣어두면
#   AWS가 목록을 갱신할 때 우리 규칙이 자동으로 따라간다.
#
# 🔴 pl- 로 시작하는 ID를 하드코딩하지 않는다.
#    리전마다 값이 다르고, 계정/시점에 따라 바뀔 수 있다.
#    region 도 변수다 (작업 규칙 4).
data "aws_ec2_managed_prefix_list" "s3" {
  name = "com.amazonaws.${var.region}.s3"
}


# ============================================================
# [1단계] SG 껍데기 4개 — 규칙 블록을 하나도 쓰지 않는다
# ============================================================
#
# ⚠️ 여기서 반드시 알아야 할 것:
#    AWS는 SG를 만들면 "아웃바운드 전체 허용" 기본 규칙을 끼워 넣는다.
#    그런데 terraform의 aws_security_group 은 egress 블록이 없으면
#    그 기본 규칙을 "제거"한다.
#    → 즉 이 껍데기들은 진짜로 규칙 0개다.
#    → 그래서 표의 "Out All 0.0.0.0/0" 도 우리가 명시적으로 만들어야 한다.
#      (자동으로 생기지 않는다)
#
# ⚠️ name 을 고정값으로 둔 이유:
#    네이밍 규칙(jangin-<env>-<resource>)을 지켜야 IAM 정책에서
#    jangin-prod-* 로 자를 수 있다. 대신 이름을 나중에 바꾸면
#    SG 교체(삭제 후 생성)가 되는데, ENI가 붙어 있으면 삭제가 막힌다.
#    → 이름은 처음에 확정하고 건드리지 않는다.

# [1] sg-alb — 인터넷과 맞닿는 유일한 SG
resource "aws_security_group" "alb" {
  name        = "${local.name}-sg-alb"
  description = "ALB. Internet 443/80 in, 8080 out to EKS nodes only."
  vpc_id      = var.vpc_id

  tags = {
    Name = "${local.name}-sg-alb"
  }
}

# [2] sg-eks-node — App 워크로드가 도는 노드 (System/App 노드그룹)
resource "aws_security_group" "eks_node" {
  name        = "${local.name}-sg-eks-node"
  description = "EKS worker nodes. 8080 from ALB, 9090 self-scrape."
  vpc_id      = var.vpc_id

  tags = {
    Name = "${local.name}-sg-eks-node"
  }
}

# [3] sg-db — CloudNativePG(Primary 1 + Replica 2)가 도는 노드
resource "aws_security_group" "db" {
  name        = "${local.name}-sg-db"
  description = "CNPG data tier. 5432 from EKS nodes only."
  vpc_id      = var.vpc_id

  tags = {
    Name = "${local.name}-sg-db"
  }
}

# [4] sg-eks-gpu — AI 추론 노드 (g6e / g4dn 공용, desired_size=0으로 대기)
resource "aws_security_group" "eks_gpu" {
  name        = "${local.name}-sg-eks-gpu"
  description = "EKS GPU nodes. 8000 inference from app nodes. No DB path."
  vpc_id      = var.vpc_id

  tags = {
    Name = "${local.name}-sg-eks-gpu"
  }
}


# ============================================================
# [2단계] 규칙 15개
# ============================================================
#
# 🔵 "Out All 0.0.0.0/0" 과 "Out 443 → S3 Prefix List" 의 중복에 대하여
#    (sg-eks-node · sg-db · sg-eks-gpu 세 곳 모두 해당)
#
#    솔직히 말하면 — 지금 이 둘은 효과가 100% 겹친다.
#    "All"은 모든 프로토콜·포트·목적지를 포함하므로 S3의 443도 이미 포함한다.
#    SG는 규칙들의 합집합(OR)으로 평가되므로 충돌도 없고, 그냥 중복이다.
#
#    그런데도 확정 표대로 둘 다 남기는 이유:
#
#    (1) 하드닝 안전망 — 보안팀이 앞으로 요구할 가능성이 가장 높은 조치가
#        "Out All 을 걷어내고 필요한 것만 열어라" 다. 그때 Out All 한 줄만
#        지우면 S3 경로는 그대로 살아남는다.
#        이 규칙이 없으면 그 순간 CNPG WAL 백업 · Loki 청크 업로드 ·
#        AI 모델 가중치 다운로드가 "동시에 조용히" 죽는다.
#        게다가 증상이 S3 권한 오류처럼 보여서 SG가 원인인 줄 모른다.
#
#    (2) 의도의 문서화 — 규칙 목록만 봐도 "이 계층은 S3를 정당하게 쓴다"가
#        드러난다. Out All 만 있으면 왜 열려 있는지 아무도 모른다.
#
#    (3) sg-db 는 지금도 이 규칙만 실제로 동작한다 — 아래 sg-db 섹션 참고.
#
#    대가: prefix list 규칙은 목록 엔트리 수만큼 SG 규칙 한도(기본 60)를
#          소모한다. 서울 리전 S3는 한 자릿수라 문제없지만 공짜는 아니다.
#
#    💡 흔한 오해: "Gateway Endpoint는 VPC 내부니까 SG가 필요 없다" → 틀렸다.
#       Endpoint로 나가는 트래픽에도 아웃바운드 SG가 그대로 적용된다.
#       다만 목적지가 S3 공인 IP가 아니라 prefix list 여야 매칭된다.


# ------------------------------------------------------------
# sg-alb — 3개
# ------------------------------------------------------------
#
# 🔵 여기 두 개만 cidr_ipv4 를 쓴다 (검수 체크리스트 #5 위반 아님)
#    "SG Reference를 쓰라"는 규칙은 양쪽 다 우리 리소스인 내부 통신에 대한
#    것이다. 인터넷 사용자는 SG를 가질 수 없으므로 SG 참조가 물리적으로
#    불가능하고, 0.0.0.0/0 이 유일한 표현이다.
#    이 파일에서 cidr_ipv4 가 나오는 곳은 여기 2개 + Out All 3개, 총 5개뿐이다.

resource "aws_vpc_security_group_ingress_rule" "alb_in_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from internet"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443

  tags = { Name = "${local.name}-sgr-alb-in-443" }
}

# 80을 여는 건 평문 서비스를 하려는 게 아니다.
# 여기서 받아야 ALB 리스너가 443으로 301 리다이렉트를 쳐줄 수 있다.
# 닫아두면 http://api.midam.store 가 리다이렉트도 못 받고 그냥 타임아웃난다.
resource "aws_vpc_security_group_ingress_rule" "alb_in_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from internet (redirected to 443 by listener rule)"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 80
  to_port     = 80

  tags = { Name = "${local.name}-sgr-alb-in-80" }
}

# ALB → Pod 전달 경로.
# 🔴 Health Check(8080 /healthz)도 이 규칙을 탄다.
#    빠뜨리면 타깃이 영원히 unhealthy 상태로 남는데,
#    ALB 화면에는 "Health checks failed" 라고만 떠서 SG 문제인 줄 모른다.
resource "aws_vpc_security_group_egress_rule" "alb_out_node_8080" {
  security_group_id = aws_security_group.alb.id
  description       = "Forward + health check to app pods"

  referenced_security_group_id = aws_security_group.eks_node.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080

  tags = { Name = "${local.name}-sgr-alb-out-8080" }
}


# ------------------------------------------------------------
# sg-eks-node — 6개
# ------------------------------------------------------------

# target-type 이 ip 라서 ALB가 Pod IP로 직접 보낸다.
# Pod IP는 VPC CNI가 노드 ENI에 붙인 보조 IP이므로 노드의 SG가 적용된다.
# → NodePort 대역(30000-32767)을 열 필요가 없다. 이게 instance 타입과의 차이다.
resource "aws_vpc_security_group_ingress_rule" "node_in_alb_8080" {
  security_group_id = aws_security_group.eks_node.id
  description       = "App traffic from ALB"

  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080

  tags = { Name = "${local.name}-sgr-node-in-8080" }
}

# 🔵 self-reference — 출처가 자기 자신(sg-eks-node)이다.
#
#    Prometheus Pod도 결국 이 SG를 단 노드 위에 뜬다.
#    그래서 "같은 SG를 달고 있는 리소스끼리만 9090 허용" 이라고 쓰면
#    노드가 2대든 10대든 IP를 손댈 일이 없다.
#
#    별도 리소스로 분리했기 때문에 자기 참조여도 Cycle이 나지 않는다.
#    (인라인 블록이었다면 SG가 자기 id를 참조하는 셈이라 순환이 된다)
#
# 🔴 sg-alb 에는 9090이 없다 — 위 「만들지 않는 것」 1번.
resource "aws_vpc_security_group_ingress_rule" "node_in_self_9090" {
  security_group_id = aws_security_group.eks_node.id
  description       = "Prometheus scrape, cluster-internal only"

  referenced_security_group_id = aws_security_group.eks_node.id
  ip_protocol                  = "tcp"
  from_port                    = 9090
  to_port                      = 9090

  tags = { Name = "${local.name}-sgr-node-in-9090-self" }
}

resource "aws_vpc_security_group_egress_rule" "node_out_db_5432" {
  security_group_id = aws_security_group.eks_node.id
  description       = "App to CNPG"

  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432

  tags = { Name = "${local.name}-sgr-node-out-5432" }
}

resource "aws_vpc_security_group_egress_rule" "node_out_gpu_8000" {
  security_group_id = aws_security_group.eks_node.id
  description       = "App to AI inference"

  referenced_security_group_id = aws_security_group.eks_gpu.id
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000

  tags = { Name = "${local.name}-sgr-node-out-8000" }
}

# 외부 연동 전부가 이 한 줄을 탄다 (⑤ NAT Gateway 경유):
#   토스페이먼츠 · 카카오/구글 OAuth · 스마트택배 · Google SMTP(587/465)
#   · ECR · STS · EC2 API
#
# ip_protocol = "-1" 은 "모든 프로토콜"이다.
# ⚠️ "-1" 일 때는 from_port/to_port 를 아예 쓰지 않는다. 쓰면 에러가 난다.
resource "aws_vpc_security_group_egress_rule" "node_out_all" {
  security_group_id = aws_security_group.eks_node.id
  description       = "Outbound via NAT GW: ECR, STS, PG, OAuth, SMTP"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"

  tags = { Name = "${local.name}-sgr-node-out-all" }
}

# ⬆ 위 Out All 과 지금은 중복이다. 남기는 이유는 이 섹션 머리말 참고.
resource "aws_vpc_security_group_egress_rule" "node_out_s3_443" {
  security_group_id = aws_security_group.eks_node.id
  description       = "S3 via Gateway Endpoint (kept for future hardening)"

  prefix_list_id = data.aws_ec2_managed_prefix_list.s3.id
  ip_protocol    = "tcp"
  from_port      = 443
  to_port        = 443

  tags = { Name = "${local.name}-sgr-node-out-s3" }
}


# ------------------------------------------------------------
# sg-db — 3개
# ------------------------------------------------------------

# 🔴 DB로 들어올 수 있는 것은 이것 하나뿐이다.
#    Bastion도, 내 노트북도, 모니터링도 직접 못 들어온다.
#    (관리는 SSM Session Manager 경유 — SSH 22는 어디에도 없다)
resource "aws_vpc_security_group_ingress_rule" "db_in_node_5432" {
  security_group_id = aws_security_group.db.id
  description       = "PostgreSQL from EKS app nodes only"

  referenced_security_group_id = aws_security_group.eks_node.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432

  tags = { Name = "${local.name}-sgr-db-in-5432" }
}

# ⚠️ 이 규칙은 확정 표대로 만들지만, 현재 구조에서는 실제로 통하지 않는다.
#
#    SG가 허용해도  →  라우트가 없으면  →  패킷은 나가지 못한다.
#    (SG = 통과 허가증 / 라우팅 테이블 = 실제로 난 길)
#
#    vpc.tf 의 rt-data 에는 0.0.0.0/0 이 없다 (작업 규칙 7 — 의도된 설계).
#    따라서 DB 노드그룹을 data 서브넷에 배치하면 ECR 이미지 pull 과
#    STS 호출이 실패한다. S3 Gateway Endpoint는 ECR "레이어"(S3에 저장)만
#    덮고, ECR API 인증(ecr.api / ecr.dkr)은 못 덮기 때문이다.
#
#    선택지: (a) DB 노드그룹을 app 서브넷에 배치 (격리는 Taint/SG/NetworkPolicy)
#            (b) rt-data 에 NAT 경로 추가 → 보안팀 NAT 조건 #2 위반
#            (c) ECR Interface Endpoint → 비용 결정($10.28 vs NAT $2.95) 번복
#
#    💡 (a)가 이미 확정된 것으로 보이는 근거 — 통합프로젝트 컨텍스트 A-3:
#         "Data 계층 = 논리적 격리 — DB 전용 노드그룹 + Taint + SG + NetworkPolicy"
#
#       "논리적" 격리라는 표현은 서브넷으로 물리 분리하는 게 아니라,
#       app 서브넷에 두고 Taint·SG·NetworkPolicy로 가른다는 뜻일 가능성이 높다.
#       나열된 수단 4가지에 "전용 서브넷"이 빠져 있는 것도 같은 방향이다.
#       이 해석이 맞으면 위 모순은 애초에 존재하지 않는다.
#
#    🔴 다만 단정하지 않는다. 서브넷 배치는 내 단독 결정 사항이 아니므로
#       여기서는 확정 표대로 두고, ⑦ 노드그룹 착수 전 파트장(강윤주) 확인을
#       PR 본문으로 요청한다. (SG 규칙 자체는 어느 안이든 동일하다)
resource "aws_vpc_security_group_egress_rule" "db_out_all" {
  security_group_id = aws_security_group.db.id
  description       = "Image pull / STS. See comment: rt-data has no 0.0.0.0/0"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"

  tags = { Name = "${local.name}-sgr-db-out-all" }
}

# 🔵 sg-db 에서는 이 규칙이 "중복이 아니다".
#    rt-data 에는 인터넷 경로가 없고 S3 Gateway Endpoint만 붙는다.
#    즉 위의 Out All 은 갈 길이 없어서 사실상 무효고,
#    CNPG의 WAL 백업이 실제로 타는 경로를 허용하는 건 이 한 줄이다.
resource "aws_vpc_security_group_egress_rule" "db_out_s3_443" {
  security_group_id = aws_security_group.db.id
  description       = "CNPG WAL/backup to S3 via Gateway Endpoint"

  prefix_list_id = data.aws_ec2_managed_prefix_list.s3.id
  ip_protocol    = "tcp"
  from_port      = 443
  to_port        = 443

  tags = { Name = "${local.name}-sgr-db-out-s3" }
}


# ------------------------------------------------------------
# sg-eks-gpu — 3개
# ------------------------------------------------------------
#
# 🔴 여기에 sg-db 로 가는 5432 규칙을 만들지 않는다.
#    (작업 규칙 8 · 검수 체크리스트 #6 — 위 「만들지 않는 것」 2번)

resource "aws_vpc_security_group_ingress_rule" "gpu_in_node_8000" {
  security_group_id = aws_security_group.eks_gpu.id
  description       = "Inference requests from app nodes (/ai/chat, /ai/products)"

  referenced_security_group_id = aws_security_group.eks_node.id
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000

  tags = { Name = "${local.name}-sgr-gpu-in-8000" }
}

# GPU 이미지(SGLang·Ollama)는 수 GB 단위라 pull 트래픽이 크다.
# NAT 처리료가 여기서 발생한다 — 막힌 항목 #5(AI 이미지 배포 경로)와 연결된다.
resource "aws_vpc_security_group_egress_rule" "gpu_out_all" {
  security_group_id = aws_security_group.eks_gpu.id
  description       = "Image pull / STS via NAT GW"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"

  tags = { Name = "${local.name}-sgr-gpu-out-all" }
}

# ⬆ 위 Out All 과 지금은 중복이다. 남기는 이유는 섹션 머리말 참고.
resource "aws_vpc_security_group_egress_rule" "gpu_out_s3_443" {
  security_group_id = aws_security_group.eks_gpu.id
  description       = "Model weights from s3-models via Gateway Endpoint"

  prefix_list_id = data.aws_ec2_managed_prefix_list.s3.id
  ip_protocol    = "tcp"
  from_port      = 443
  to_port        = 443

  tags = { Name = "${local.name}-sgr-gpu-out-s3" }
}
