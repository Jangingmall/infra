# ============================================================
# modules/nat/variables.tf — 이 모듈이 밖에서 받아야 하는 값
# ------------------------------------------------------------
# 🔴 모듈 변수에는 default 를 두지 않는다. (검수 체크리스트 14)
#    default 가 있으면 environments/ 에서 값을 빠뜨려도 조용히
#    엉뚱한 값으로 만들어진다. 기본값은 environments/*/variables.tf 에만.
#
# 🔴 모듈 내부 변수명에는 nat_ 접두사를 붙이지 않는다. (B안 컨벤션)
#    모듈 이름 자체가 nat 이므로 nat_enabled 는 nat.nat_enabled 가 되어 중복이다.
#    접두사는 루트(environments/*/variables.tf)에서만 붙인다.
# ============================================================

variable "project" {
  description = "프로젝트 식별자. 리소스 이름의 맨 앞에 붙는다. (예: jangin)"
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

variable "enabled" {
  description = <<-EOT
    NAT Gateway 생성 여부.
    false 로 두면 NAT 와 app 라우팅 경로, 알람만 사라지고
    EIP(고정 공인 IP)는 남는다.
    → 10/1~10/4 환경을 내릴 때 값 하나로 시간당 요금을 끊되,
      스마트택배 allowlist 에 등록된 공인 IP 는 유지된다. (작업 규칙 9)
  EOT
  type        = bool
}

variable "public_subnet_ids_by_az" {
  description = <<-EOT
    AZ 접미사 → Public 서브넷 ID map.
    module.network.public_subnet_ids_by_az 를 그대로 넘긴다.

    🔴 NAT 는 반드시 Public 서브넷에 둬야 한다.
       NAT 자신이 IGW 로 나갈 수 있어야 하기 때문이다.
       App 서브넷에 두면 자기도 못 나가서 아무 의미가 없다.
  EOT
  type        = map(string)
}

variable "az_suffix" {
  description = <<-EOT
    NAT Gateway 를 둘 AZ 접미사. public_subnet_ids_by_az 의 키여야 한다.
    MVP 는 AZ-a 단일이며, 이 경우 해당 AZ 장애 시 아웃바운드 전체가 끊긴다
    (보안팀 NAT 승인 조건 #5 — 문서화 대상).
    멀티 AZ NAT 로 가려면 app 라우팅 테이블도 AZ 별로 쪼개야 한다.
  EOT
  type        = string
}

variable "app_route_table_id" {
  description = <<-EOT
    NAT 경로(0.0.0.0/0)를 추가할 App 라우팅 테이블 ID.

    🔴 Data 라우팅 테이블 ID 를 넣지 않는다.
       Data 계층 인터넷 직접 접근 금지 (작업 규칙 7 · 보안팀 NAT 조건 #2).
       그래서 이 변수는 list 가 아니라 단수 string 이다 — 실수로 여러 개를
       넣을 수 없게 타입으로 막아둔 것이다.
  EOT
  type        = string
}

variable "internet_gateway_id" {
  description = <<-EOT
    같은 VPC 의 Internet Gateway ID.

    🔑 이 값을 실제로 "쓰지는" 않는다. 순서를 만들기 위해 받는다.
       NAT 는 IGW 가 먼저 있어야 동작하는데, 코드상 IGW 를 참조할 일이 없어
       그냥 두면 Terraform 이 둘을 동시에 만들려 한다.
       main.tf 의 precondition 에서 이 값을 검사하게 해서
       "IGW 가 만들어질 때까지 NAT 는 기다린다" 를 만든다. 자세한 설명은 main.tf.
  EOT
  type        = string
}

variable "alarm_sns_topic_arns" {
  description = <<-EOT
    CloudWatch 알람이 알림을 보낼 SNS 토픽 ARN 목록.
    🟡 Budget 알림 SNS 재사용 여부가 미확정이라 기본은 빈 목록으로 둔다.
       빈 목록이면 지표와 알람 상태는 정상 동작하고 알림만 나가지 않는다
       — 보안팀 검수 자료로는 충분하다.
  EOT
  type        = list(string)
}
