# ============================================================
# modules/eks_nodes/variables.tf — 이 모듈이 밖에서 받아야 하는 값
# ------------------------------------------------------------
# 🔴 모듈 변수에는 default 를 두지 않습니다. (검수 체크리스트 14)
#    값을 빠뜨렸을 때 조용히 넘어가지 않고 실패해야 합니다.
# 🔴 모듈 내부 변수명에는 eks_nodes_ 접두사를 붙이지 않습니다. (B안 컨벤션)
# ============================================================

variable "project" {
  description = "프로젝트 식별자. 리소스 이름 맨 앞에 붙는다. (예: jangin)"
  type        = string
}

variable "env" {
  description = "환경 구분. prod | staging"
  type        = string

  validation {
    condition     = contains(["prod", "staging"], var.env)
    error_message = "env 는 prod 또는 staging 만 허용합니다."
  }
}

# ------------------------------------------------------------
# 클러스터 연결
# ------------------------------------------------------------

variable "cluster_name" {
  description = "노드가 조인할 EKS 클러스터 이름. module.eks.cluster_name 을 넘긴다."
  type        = string
}

variable "cluster_version" {
  description = <<-EOT
    노드에 쓸 쿠버네티스 버전.
    🔴 컨트롤플레인보다 높으면 안 됩니다. 같은 값을 넘기는 것이 기본입니다.
       (AWS 는 컨트롤플레인보다 낮은 노드는 일정 범위까지 허용하지만 높은 노드는 거부합니다)
  EOT
  type        = string
}

variable "subnet_ids" {
  description = <<-EOT
    노드를 배치할 서브넷 ID 목록. app(private) 서브넷을 넘긴다.

    🔴 public 서브넷에 두지 않습니다. 노드가 공인 IP 를 갖게 되어
       "인터넷에서 직접 닿는 서버" 가 되기 때문입니다. 아웃바운드는 NAT 로 나갑니다.
  EOT
  type        = list(string)
}

# ------------------------------------------------------------
# 보안그룹
# ------------------------------------------------------------
variable "cluster_security_group_id" {
  description = <<-EOT
    EKS 가 자동 생성한 클러스터 SG (eks-cluster-sg-<클러스터명>).
    module.eks.cluster_security_group_id 를 넘긴다.

    🔴 이 변수가 존재하는 이유가 이 모듈에서 가장 중요합니다.
       Launch Template 에 vpc_security_group_ids 를 "하나라도" 지정하면
       EKS 는 클러스터 SG 를 자동으로 붙여주지 않습니다.
       이 SG 가 빠지면 노드 ↔ 컨트롤플레인 통신이 막혀
       노드가 NotReady 에서 영원히 멈춥니다 (조인 자체 실패).
    → locals.tf 에서 항상 목록 맨 앞에 concat 합니다.
  EOT
  type        = string
}

variable "security_groups_by_workload_type" {
  description = <<-EOT
    labels 의 workload-type 값 → 그 노드에 추가로 붙일 SG ID 목록.
      { system = [...], app = [...], db = [...], gpu = [...] }

    🔑 왜 노드그룹 키(system-md 등)가 아니라 workload-type 으로 묶는가:
       system-md 와 system-lg 는 인스턴스 타입만 다르고 역할이 같습니다.
       라벨을 기준으로 하면 노드그룹을 더 쪼개도 SG 매핑을 고칠 일이 없습니다.

    🔴 여기에 없는 workload-type 이 들어오면 main.tf 의 precondition 이 막습니다.
       그냥 두면 클러스터 SG 만 붙은 채로 조용히 생성되고,
       ALB → Pod 트래픽이 "Health checks failed" 로만 나타나 원인 추적이 어렵습니다.
  EOT
  type        = map(list(string))
}

# ------------------------------------------------------------
# 노드그룹 정의
# ------------------------------------------------------------

variable "node_groups" {
  description = <<-EOT
    노드그룹 정의 map. 키가 곧 노드그룹 이름의 접미사가 된다.
      예) "system-md" → jangin-prod-ng-system-md

    각 항목
      enabled         이 그룹을 만들지 여부. false 면 아예 만들지 않는다
      instance_type   EC2 인스턴스 타입 (그룹당 하나)
      desired_size    시작 노드 수
      min_size        최소 노드 수
      max_size        최대 노드 수
      capacity_type   ON_DEMAND | SPOT
      ami_type        AL2023_x86_64_STANDARD (일반) | AL2023_x86_64_NVIDIA (GPU)
      disk_size       루트 EBS 용량(GB)
      labels          노드에 붙는 라벨. Pod 의 nodeSelector 가 이 값을 본다
      taints          노드가 Pod 를 거부하는 표찰. 아래 「Label 과 Taint」 참고

    🔑 Label 과 Taint 는 반대 방향으로 동작합니다
       Label  + nodeSelector = Pod 가 "나는 이 노드로 가겠다" (Pod 의 의사)
       Taint  + toleration   = 노드가 "출입증 없으면 못 들어온다" (노드의 거부)
       둘 다 있어야 "이 Pod 만 이 노드에" 가 성립합니다.
       출입증만 있고 의사가 없으면 다른 노드에 갈 수도 있습니다.

    ⚠️ DB 그룹만 Label 키(workload-type)와 Taint 키(workload)가 다릅니다.
       오타가 아니라 CN 매니페스트(k8s/base/database/cluster.yaml) 실물이 그렇습니다.
       통일하면 CNPG Pod 가 뜨지 않습니다.
  EOT

  type = map(object({
    enabled       = bool
    instance_type = string
    ami_type      = string
    desired_size  = number
    min_size      = number
    max_size      = number
    capacity_type = string
    disk_size     = number
    labels        = map(string)
    taints = list(object({
      key    = string
      value  = string
      effect = string # NO_SCHEDULE | NO_EXECUTE | PREFER_NO_SCHEDULE
    }))
  }))
}

variable "node_role_extra_policy_arns" {
  description = <<-EOT
    노드 IAM 역할에 추가로 붙일 AWS 관리형 정책 ARN 목록.
    기본 3종(WorkerNode·CNI·ECR ReadOnly)과 SSM 은 모듈이 항상 붙이므로 여기 넣지 않는다.
    비어 있어도 된다.
  EOT
  type        = list(string)
}

variable "ssh_key_name" {
  description = <<-EOT
    노드에 넣을 EC2 키페어 이름. **null 을 권장합니다.**

    🔴 SSH(22) 는 설계상 차단이고 접근은 SSM Session Manager 로만 합니다.
       키페어를 넣으면 "열어둔 경로" 가 하나 생기고 보안팀 지적 대상이 됩니다.
  EOT
  type        = string
}
