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
  disk_size      = each.value.disk_size

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

  # 🔴 SSH 키를 넣지 않습니다.
  #    접근은 SSM Session Manager 로만 합니다(설계상 SSH 22 차단).
  #    키를 넣으면 "열어둔 경로" 가 하나 생기고 보안팀 지적 대상이 됩니다.
  dynamic "remote_access" {
    for_each = var.ssh_key_name == null ? [] : [1]
    content {
      ec2_ssh_key = var.ssh_key_name
    }
  }

  tags = merge(
    {
      Name = "${local.name}-ng-${each.key}"
    },
    # 💰 NodePool 태그는 과금 리소스에만 붙입니다 (작업 규칙 10).
    #    노드그룹은 EC2·EBS 를 만드는 과금 리소스이므로 대상입니다.
    #    값은 system|app|db|ai 중 하나여야 Cost Explorer 필터가 의미를 갖습니다.
    lookup(each.value.labels, "workload-type", null) == null ? {} : {
      NodePool = each.value.labels["workload-type"] == "gpu" ? "ai" : each.value.labels["workload-type"]
    }
  )

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
    # 그래서 min_size 도 3 이어야 합니다. desired 만 3 이고 min 이 2 면
    # 오토스케일러나 노드 교체 과정에서 2대로 내려가는 순간 복구가 안 됩니다.
    precondition {
      condition = (
        lookup(each.value.labels, "workload-type", "") != "db"
        || each.value.min_size >= 3
      )
      error_message = "노드그룹 '${each.key}': DB 그룹은 min_size 가 3 이상이어야 합니다. CNPG 의 podAntiAffinityType=required 때문에 Pod 3개가 서로 다른 노드를 요구합니다."
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
