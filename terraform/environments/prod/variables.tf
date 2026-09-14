# ============================================================
# variables.tf — 입력 변수
# ------------------------------------------------------------
# 역할: 환경마다 달라지는 값(리전·CIDR·환경명)을 코드 본문에서
#       떼어내, staging을 만들 때 값만 바꿔 끼울 수 있게 한다.
# ============================================================

variable "project" {
  description = "프로젝트 식별자. 모든 리소스 이름의 맨 앞에 붙는다."
  type        = string
  default     = "jangin"
}

variable "env" {
  description = "환경 구분. 리소스 이름과 Environment 태그에 쓰인다."
  type        = string
  default     = "prod"

  # 오타 방지. "prd" 나 "production" 으로 잘못 쓰면
  # jangin-prd-vpc 같은 리소스가 생기고, IAM 정책의
  # jangin-prod-* 패턴에서 빠져나가 버린다.
  validation {
    condition     = contains(["prod", "staging"], var.env)
    error_message = "env 는 prod 또는 staging 만 허용합니다."
  }
}

variable "region" {
  description = "AWS 리전. 작업 규칙 4에 따라 하드코딩하지 않는다."
  type        = string
  default     = "ap-northeast-2"
}

# ------------------------------------------------------------
# 네트워크 — CLAUDE.md 「네트워크 확정값」 표와 1:1 대조할 것
# ------------------------------------------------------------

variable "vpc_cidr" {
  description = "VPC CIDR. prod = 10.0.0.0/16 / staging = 10.1.0.0/16"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_suffixes" {
  description = <<-EOT
    사용할 가용영역(AZ) 접미사. region 과 합쳐 실제 AZ 이름을 만든다.
    예: region=ap-northeast-2 + "a" => ap-northeast-2a

    AZ 이름 자체를 하드코딩하지 않기 위한 구조다 (작업 규칙 4).
    2개인 이유: ALB가 최소 2개 AZ의 서브넷을 요구한다.
    (실제 리소스는 MVP 방침상 AZ-a 에만 배치)
  EOT
  type        = list(string)
  default     = ["a", "c"]
}

variable "subnet_cidrs" {
  description = <<-EOT
    tier별 · AZ별 서브넷 CIDR.

    🔴 app 계층만 /20 인 이유:
       EKS VPC CNI는 Pod 하나마다 VPC의 실제 IP를 하나씩 준다.
       /24(약 250개)로는 Pod가 늘어나면 IP가 고갈되고,
       CIDR은 서브넷을 만든 뒤에는 절대 바꿀 수 없다.
       → /24 로 "정리"하지 말 것. (검수 체크리스트 #1)
  EOT

  type = object({
    public = map(string)
    app    = map(string)
    data   = map(string)
  })

  # prod 확정값. 계산 함수(cidrsubnet)로도 뽑을 수 있지만,
  # PR 리뷰에서 CLAUDE.md 표와 눈으로 대조해야 하므로 리터럴로 둔다.
  default = {
    public = {
      a = "10.0.0.0/24"
      c = "10.0.1.0/24"
    }
    app = {
      a = "10.0.16.0/20" # 🔴 /20
      c = "10.0.32.0/20" # 🔴 /20
    }
    data = {
      a = "10.0.2.0/24"
      c = "10.0.3.0/24"
    }
  }
}

# ------------------------------------------------------------
# EKS 연동
# ------------------------------------------------------------

variable "cluster_name" {
  description = <<-EOT
    EKS 클러스터 이름. 서브넷의 kubernetes.io/cluster/<이름> 태그에 쓰인다.

    TODO(⑥ EKS 단계에서 확정값 재확인)
      CLAUDE.md에 클러스터명이 명시돼 있지 않아, 네이밍 규칙
      jangin-<env>-<resource> 에서 유도한 잠정값이다.
      ⑥에서 실제 생성할 클러스터 이름과 일치하는지 반드시 대조할 것.
      (불일치 시 태그가 무의미해지는 정도이고 파괴적이지는 않다)
  EOT
  type        = string
  default     = "jangin-prod-eks-cluster"
}
