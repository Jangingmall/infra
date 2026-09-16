# ============================================================
# modules/eks/variables.tf — IaC ⑥ EKS 클러스터 + OIDC Provider
# ------------------------------------------------------------
# 🔴 모듈 변수에는 default 를 두지 않습니다.
#    default 가 있으면 환경에서 값을 빠뜨려도 조용히 엉뚱한 값으로 만들어집니다.
# ============================================================

variable "project" {
  description = "프로젝트 식별자 (예: jangin)"
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

variable "region" {
  description = "AWS 리전. kubeconfig 안내 문구를 만드는 데 쓰입니다."
  type        = string
}

variable "cluster_name" {
  description = <<-EOT
    EKS 클러스터 이름.
    🔴 서브넷의 kubernetes.io/cluster/<이름> 태그와 반드시 일치해야 합니다.
       (modules/network 에 같은 값이 들어갑니다)
  EOT
  type = string
}

variable "cluster_version" {
  description = <<-EOT
    쿠버네티스 버전 (예: "1.33").

    🔴 만든 뒤 올릴 수는 있어도 내릴 수 없습니다. 첫 선택이 전부입니다.
    🔴 확장 지원(Extended Support) 구간 버전은 시간당 추가 요금이 붙습니다.
       예산이 98.8% 소진 상태라 반드시 피해야 합니다.

    확인 명령:
      aws eks describe-cluster-versions --region ap-northeast-2 --profile jangin --output table
    → STANDARD_SUPPORT 이면서 AWS 기본(default) 인 버전을 고릅니다.
  EOT
  type = string
}

variable "subnet_ids" {
  description = <<-EOT
    컨트롤플레인 ENI 를 둘 서브넷 ID 목록.
    🔴 서로 다른 AZ 2개 이상이 필수입니다 (EKS 요구사항).
    app(private) 서브넷을 넣습니다 — 컨트롤플레인 ENI 에 공인 IP 를 주지 않기 위함입니다.
  EOT
  type = list(string)
}

variable "additional_security_group_ids" {
  description = <<-EOT
    컨트롤플레인 ENI 에 추가로 붙일 SG 목록.

    ⚠️ 보통 비워 둡니다. EKS 가 eks-cluster-sg-<클러스터명> 을 자동으로 만들어
       컨트롤플레인 ↔ 노드 통신을 알아서 열기 때문입니다.
       (이 자동 SG 가 3-tier 방어 논리의 핵심 근거이기도 합니다)
  EOT
  type = list(string)
}

variable "endpoint_public_access" {
  description = <<-EOT
    컨트롤플레인 API 를 인터넷에서 접근 가능하게 할지 여부.

    ⚠️ "공개"라도 아무나 들어오는 게 아닙니다. 인증 명부(Access Entry / aws-auth)에
       없으면 401 입니다. 여기서 정하는 건 "전화선 연결 여부"이지 "문이 열려 있는지"가 아닙니다.
    🔴 false 로 두면 VPC 안에서만 kubectl 이 되므로, Bastion 없는 현 구조에서는
       SSM 경유 접속 환경을 따로 만들어야 합니다.
  EOT
  type = bool
}

variable "endpoint_private_access" {
  description = "VPC 내부에서 컨트롤플레인 API 에 접근 가능하게 할지 여부. 노드 통신 안정성을 위해 true 권장."
  type        = bool
}

variable "public_access_cidrs" {
  description = <<-EOT
    endpoint_public_access = true 일 때 접근을 허용할 출발지 CIDR 목록.

    🟡 팀원 6명이 고정 IP 를 쓰지 않아 CIDR 제한이 현실적으로 운영 불가합니다.
       (바꿀 때마다 apply 가 필요하고 컨트롤플레인이 5~10분 갱신됩니다)
       → 보안팀에는 "공개 + 인증 명부 최소화 + 감사 로그" 조합으로 조건부 승인을 요청합니다.
  EOT
  type = list(string)
}

variable "authentication_mode" {
  description = <<-EOT
    클러스터 접근 권한 명부를 어디에 둘지.

      CONFIG_MAP          클러스터 안의 aws-auth ConfigMap (구 방식)
      API                 AWS 쪽 Access Entry (신 방식)
      API_AND_CONFIG_MAP  둘 다 인정

    🔴 좁히는 방향(API_AND_CONFIG_MAP → API)으로만 바꿀 수 있습니다. 반대는 불가.
    🔴 CONFIG_MAP 전용에서 명부를 잘못 쓰면 아무도 클러스터에 못 들어가고,
       고치려면 클러스터에 들어가야 해서 복구가 불가능합니다
       (열쇠를 방 안에 두고 문을 잠그는 상황). EKS 사고 1위 유형입니다.
  EOT
  type = string

  validation {
    condition     = contains(["CONFIG_MAP", "API", "API_AND_CONFIG_MAP"], var.authentication_mode)
    error_message = "authentication_mode 는 CONFIG_MAP · API · API_AND_CONFIG_MAP 중 하나여야 합니다."
  }
}

variable "bootstrap_cluster_creator_admin_permissions" {
  description = <<-EOT
    클러스터를 만든 주체에게 자동으로 관리자 권한을 줄지 여부.

    🔴 9/15~17 한시적 admin 회수와 충돌할 수 있습니다.
       회수 대상 권한으로 클러스터를 만들면 회수 후 아무도 못 들어갑니다.
       → 회수 후에도 남는 역할(Infra-Admin Permission Set)로 apply 해야 합니다. (박다정 확인)
    ⚠️ 이 값은 생성 시점에만 의미가 있고 나중에 바꿔도 이미 부여된 권한은 회수되지 않습니다.
  EOT
  type = bool
}

variable "enabled_cluster_log_types" {
  description = <<-EOT
    CloudWatch 로 내보낼 컨트롤플레인 로그 종류.
    ["api", "audit", "authenticator"] 가 보안 검수용 최소 조합입니다.

    💰 CloudWatch Logs 수집·보관 요금이 발생합니다 (비용 산정서 미반영 — 소액이나 확인 필요).
    빈 목록 []) 으로 두면 로그를 끕니다.
  EOT
  type = list(string)
}

variable "log_retention_days" {
  description = <<-EOT
    컨트롤플레인 로그 보관 기간(일).
    🔴 로그 그룹을 Terraform 이 먼저 만들지 않으면 EKS 가 "보관 기간 무제한"으로 만들어버립니다.
       프로젝트가 끝나도 요금이 계속 나가는 대표적인 함정입니다.
  EOT
  type = number
}

variable "secrets_kms_key_arn" {
  description = <<-EOT
    쿠버네티스 Secret 을 봉투 암호화할 KMS CMK ARN. null 이면 미적용.
    🟡 ⑧ KMS 단계에서 채웁니다. 🔴 클러스터 생성 후에는 해제할 수 없습니다(추가만 가능).
  EOT
  type = string
}
