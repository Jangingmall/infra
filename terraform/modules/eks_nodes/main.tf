# ============================================================
# modules/eks_nodes/main.tf — EKS 관리형 노드그룹 (IaC ⑦)   💰 유료
# ------------------------------------------------------------
# 무엇을 하는 물건인가 (쉽게):
#   ⑥ 에서 만든 EKS 클러스터는 "관리 사무소"일 뿐, 실제로 Pod 가 도는 서버가 없습니다.
#   이 모듈이 그 서버(EC2)를 역할별로 묶어 만듭니다.
#
#   "관리형(managed)" 노드그룹은 AWS 가 AMI 선택·조인·교체를 대신해 줍니다.
#   우리가 직접 EC2 를 띄우고 kubelet 을 붙이는 것(self-managed)보다 훨씬 단순합니다.
#
# 💰 전체 비용의 상당 부분이 여기서 발생합니다. 특히 GPU 2대가 비용의 약 63%.
#    작업 규칙 17 — apply 는 9/18 일괄.
#
# ------------------------------------------------------------
# 🔴 이 모듈의 값은 CN(박명수님) 매니페스트 실물에서 역산했습니다
#
#   k8s/base/backend/rollout.yaml        nodeSelector: workload-type=app
#   k8s/base/database/cluster.yaml       nodeSelector: workload-type=db
#                                        toleration:   workload=db:NoSchedule
#                                        podAntiAffinityType: required
#   k8s/base/ai/deployment.yaml          nodeSelector: workload-type=gpu, gpu-model=l40s
#   k8s/base/ai/ollama-deployment.yaml   nodeSelector: workload-type=gpu, gpu-model=t4
#                                        toleration:   nvidia.com/gpu=true:NoSchedule
#   platform/*/values.yaml               nodeSelector: workload-type=system
#
#   🔴 한 글자라도 다르면 해당 Pod 가 영원히 Pending 입니다. 임의로 고치지 마세요.
# ============================================================


# ------------------------------------------------------------
# 노드 IAM 역할
# ------------------------------------------------------------
# 노드(EC2)가 AWS 에게 자기를 증명하는 신분증입니다.
# 모든 노드그룹이 이 역할 하나를 공유합니다 — 그룹마다 나눌 이유가 없고,
# 나누면 정책 4종을 그룹 수만큼 복사해야 해서 누락이 생깁니다.
data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${local.name}-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = {
    Name = "${local.name}-eks-node-role"
  }
}

resource "aws_iam_role_policy_attachment" "node_base" {
  for_each = local.base_node_policies

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# 환경에서 추가로 붙이고 싶은 정책이 있을 때만 사용합니다.
# (현재는 빈 목록. ⑧ IRSA 가 Pod 단위 권한을 담당하므로 노드에 권한을 얹을 일이 거의 없습니다)
#
# 🔴 노드 역할에 권한을 붙이면 "그 노드에 뜬 모든 Pod" 가 그 권한을 갖습니다.
#    Pod 단위로 권한을 주려면 노드가 아니라 IRSA 를 써야 합니다.
resource "aws_iam_role_policy_attachment" "node_extra" {
  for_each = toset(var.node_role_extra_policy_arns)

  role       = aws_iam_role.node.name
  policy_arn = each.value
}


# ------------------------------------------------------------
# 노드그룹
# ------------------------------------------------------------
data "aws_default_tags" "current" {}

# EC2·EBS 비용 태그는 Launch Template에서 부여한다.
# 기존 노드그룹에 처음 연결할 때는 교체 계획과 DB 볼륨 AZ를 확인해야 한다.
resource "aws_launch_template" "node" {
  for_each = local.enabled_groups

  name_prefix = "${local.name}-ng-${each.key}-"
  key_name    = var.ssh_key_name

  # 🔴 이 한 줄이 없으면 노드에 클러스터 SG 만 붙습니다.
  #    그러면 modules/security 의 SG 4종 중 3종(eks-node·db·gpu)과
  #    규칙 12개가 아무 데도 적용되지 않는 코드가 됩니다.
  #    특히 sg-alb 의 유일한 egress 가 "→ sg-eks-node" 라,
  #    ALB 가 Pod 로 패킷을 보내지 못해 타깃이 영구 unhealthy 가 됩니다.
  vpc_security_group_ids = local.node_security_group_ids[each.key]

  # ── IMDSv2 강제 ───────────────────────────────────────────
  # 커스텀 LT 를 쓰면 EKS 기본값이 아니라 EC2 기본값(IMDSv1 허용)이 적용됩니다.
  # 노드 역할에는 AmazonEKS_CNI_Policy 까지 붙어 있어,
  # 앱의 SSRF 취약점 하나로 노드 자격증명이 그대로 나갑니다 (DAST 지적 대상).
  #
  # hop_limit = 1 은 Pod 에서 IMDS 로 가는 경로를 끊습니다.
  # 이 레포는 Pod 권한을 전부 IRSA 로 주므로 워크로드에는 영향이 없습니다.
  # (aws-node·kube-proxy·ebs-csi-node 는 hostNetwork 라 그대로 동작)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  # AL2023 EKS AMI의 루트 장치. 용량은 기존 그룹별 설정을 보존한다.
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = each.value.disk_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  dynamic "tag_specifications" {
    for_each = toset(["instance", "volume"])
    content {
      resource_type = tag_specifications.value
      tags          = local.node_tags[each.key]
    }
  }

  tags = { Name = "${local.name}-lt-${each.key}" }

  lifecycle {
    # 🔴 매핑 누락을 여기서 잡습니다.
    #    새 workload-type 라벨을 추가했는데 SG 매핑을 안 넣으면,
    #    그 노드는 클러스터 SG 만 달고 조용히 생성됩니다.
    #    증상이 "ALB 헬스체크 실패" 로만 나타나 SG 문제인 줄 모릅니다.
    precondition {
      condition = contains(
        keys(var.security_groups_by_workload_type),
        lookup(each.value.labels, "workload-type", ""),
      )
      error_message = "노드그룹 '${each.key}': labels 의 workload-type 이 security_groups_by_workload_type 에 없습니다. 환경의 nodegroups.tf 에서 매핑을 추가하세요."
    }
  }
}

resource "aws_eks_node_group" "this" {
  for_each = local.enabled_groups

  cluster_name    = var.cluster_name
  node_group_name = "${local.name}-ng-${each.key}"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  version         = var.cluster_version

  # 🔴 한 그룹에 인스턴스 타입 하나가 원칙입니다.
  #    instance_types 에 여러 개를 줄 수는 있지만 그건 Spot 용 "선택지 목록"이고,
  #    온디맨드에서는 어느 타입이 뜰지 보장되지 않습니다.
  #    "medium 1대 + large 1대" 를 확실히 하려면 그룹을 나누는 것이 유일한 방법입니다.
  instance_types = [each.value.instance_type]
  capacity_type  = each.value.capacity_type
  ami_type       = each.value.ami_type

  launch_template {
    id      = aws_launch_template.node[each.key].id
    version = tostring(aws_launch_template.node[each.key].latest_version)
  }

  scaling_config {
    desired_size = each.value.desired_size
    min_size     = each.value.min_size
    max_size     = each.value.max_size
  }

  # 노드를 교체할 때 한 번에 몇 대까지 내릴지.
  # 1 로 두면 느리지만 안전합니다 — DB 그룹은 3대 전부가 필요해서 특히 중요합니다.
  update_config {
    max_unavailable = 1
  }

  labels = each.value.labels

  # Taint = 노드가 거는 "관계자 외 출입금지" 표찰.
  # 이 표찰을 통과하려면 Pod 에 toleration(출입증)이 있어야 합니다.
  dynamic "taint" {
    for_each = each.value.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  # key_name은 Launch Template으로 전달하며 SSH 인바운드는 추가하지 않는다.
  tags = local.node_tags[each.key]

  lifecycle {
    # ── 사이즈 정합성 ─────────────────────────────────────────
    precondition {
      condition = (
        each.value.desired_size >= each.value.min_size
        && each.value.desired_size <= each.value.max_size
      )
      error_message = "노드그룹 '${each.key}': desired_size 는 min_size 이상 max_size 이하여야 합니다."
    }

    # ── 🔴 DB 그룹 3대 제약 ───────────────────────────────────
    #
    # CN 매니페스트의 podAntiAffinityType: required + topologyKey: hostname 은
    # "CNPG Pod 3개가 반드시 서로 다른 노드에" 를 뜻합니다.
    # Pod 3 : 노드 3 이라 여유가 0 이고, 1대만 줄어도 Pod 하나가 영구 Pending 입니다.
    #
    # 운영 중에는 min_size도 3 이상이어야 합니다. 전체 중지는 min/desired 둘 다 0일 때만 허용합니다.
    # 오토스케일러나 노드 교체 과정에서 2대로 내려가는 순간 복구가 안 됩니다.
    precondition {
      condition = (
        lookup(each.value.labels, "workload-type", "") != "db"
        || each.value.min_size >= 3
        || (each.value.min_size == 0 && each.value.desired_size == 0)
      )
      error_message = "노드그룹 '${each.key}': DB 그룹은 운영 시 min_size가 3 이상이어야 합니다. 전체 중지는 min_size와 desired_size가 모두 0일 때만 허용하며 1~2대 부분 축소는 금지합니다."
    }

    # ── 🔴 DB 그룹 Spot 금지 ──────────────────────────────────
    #
    # Spot 은 AWS 가 용량이 필요하면 2분 통보 후 회수합니다.
    # DB 는 여유 노드가 0 이라, 한 대가 회수되면 그 Pod 가 갈 곳이 없습니다.
    precondition {
      condition = (
        lookup(each.value.labels, "workload-type", "") != "db"
        || each.value.capacity_type == "ON_DEMAND"
      )
      error_message = "노드그룹 '${each.key}': DB 그룹은 ON_DEMAND 여야 합니다. Spot 회수 시 CNPG Pod 가 복구되지 않습니다."
    }
  }

  # 🔴 IAM 정책이 붙기 전에 노드가 뜨면 클러스터 조인에 실패합니다.
  #    표현할 수 없는 의존성이라 depends_on 을 씁니다 (HashiCorp 공식 문서도 이 경우를 명시).
  depends_on = [aws_iam_role_policy_attachment.node_base]
}
