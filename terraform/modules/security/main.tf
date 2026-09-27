# ============================================================
# security_group.tf — Security Group 4종 + 규칙 17개
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
#    → 그래서 egress 는 아래 [2단계] 에서 필요한 것만 명시적으로 만든다.
#      (기본 Out All 은 자동으로 생기지 않고, 우리도 만들지 않는다)
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
# [2단계] 규칙 17개
# ============================================================
#
# 🔵 egress 는 "허용 목록" 방식이다 (Trivy AWS-0104 대응 · 09-27)
#    sg-eks-node · sg-db · sg-eks-gpu 에 있던 Out All(-1, 0.0.0.0/0) 3개를 걷어내고
#    필요한 포트만 연다 — 외부 443 / SMTP 465·587(node 만) / S3 prefix list 443.
#
#    - DNS(53)·NTP(123) 규칙은 일부러 없다. Amazon DNS(VPC+2)·Time Sync·IMDS 는
#      SG 가 필터링하지 않는 트래픽이라 규칙 없이도 통한다.
#    - S3 prefix list 443 은 이제 중복이 아니다. 이 규칙이 빠지면 CNPG WAL 백업 ·
#      Loki 청크 업로드 · AI 모델 가중치 다운로드가 "동시에 조용히" 죽고,
#      증상이 S3 권한 오류처럼 보여서 SG 가 원인인 줄 모른다.\
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
#    이 파일에서 cidr_ipv4 가 나오는 곳은 여기 2개 + egress 허용 목록 5개, 총 7개뿐이다.

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
# sg-eks-node — 8개
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

# 외부 연동(SMTP 제외)이 전부 이 한 줄을 탄다 (⑤ NAT Gateway 경유):
#   토스페이먼츠 · 카카오/구글/네이버 OAuth · 스마트택배 · ECR · STS · EC2 API
#   + kubelet → EKS API 엔드포인트
# 🔴 "외부 API 용" 으로 보고 지우면 노드가 NotReady 가 된다.
resource "aws_vpc_security_group_egress_rule" "node_out_https" {
  security_group_id = aws_security_group.eks_node.id
  description       = "HTTPS via NAT GW: ECR, STS, EC2 API, EKS API, PG, OAuth, courier API"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443

  tags = { Name = "${local.name}-sgr-node-out-443" }
}

# Google SMTP - Backend Pod 만 쓰므로 sg-eks-node 에만 연다 (db, gpu 에는 없음)
# 안 쓰는 쪽을 map 에서 한 줄 지우기
resource "aws_vpc_security_group_egress_rule" "node_out_smtp" {
  for_each = { smtps = 465, submission = 587 }

  security_group_id = aws_security_group.eks_node.id
  description       = "Google SMTP (${each.key}) via NAT GW"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = each.value
  to_port     = each.value

  tags = { Name = "${local.name}-sgr-node-out-${each.value}" }
}

# Loki 청크 업로드 · 이미지 presigned 처리 등 S3 경로. 빠지면 조용히 실패한다 (섹션 머리말 참고).
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

resource "aws_vpc_security_group_ingress_rule" "db_in_node_5432" {
  security_group_id = aws_security_group.db.id
  description       = "PostgreSQL from EKS app nodes only"

  referenced_security_group_id = aws_security_group.eks_node.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432

  tags = { Name = "${local.name}-sgr-db-in-5432" }
}

# CNPG 이미지 pull(ECR), IRSA(STS), Kubernetes API 호출 전부 443\
resource "aws_vpc_security_group_egress_rule" "db_out_https" {
  security_group_id = aws_security_group.db.id
  description       = "HTTPS via NAT GW: ECR image pull, STS, EKS API"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443

  tags = { Name = "${local.name}-sgr-db-out-443" }
}

# CNPG 의 WAL·베이스 백업이 실제로 타는 경로 (S3 Gateway Endpoint).
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
# NAT 처리료가 여기서 발생한다 — 막힌 항목 #4(AI 이미지 배포 경로)와 연결된다.
resource "aws_vpc_security_group_egress_rule" "gpu_out_https" {
  security_group_id = aws_security_group.eks_gpu.id
  description       = "HTTPS via NAT GW: ECR image pull, STS, EKS API"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443

  tags = { Name = "${local.name}-sgr-gpu-out-443" }
}

# s3-models 가중치 다운로드 경로. NAT 를 안 타므로 처리료가 없다.
resource "aws_vpc_security_group_egress_rule" "gpu_out_s3_443" {
  security_group_id = aws_security_group.eks_gpu.id
  description       = "Model weights from s3-models via Gateway Endpoint"

  prefix_list_id = data.aws_ec2_managed_prefix_list.s3.id
  ip_protocol    = "tcp"
  from_port      = 443
  to_port        = 443

  tags = { Name = "${local.name}-sgr-gpu-out-s3" }
}
