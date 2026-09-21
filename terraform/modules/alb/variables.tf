# [ALB] 모듈 입력 변수 정의

variable "name" {
  description = "ALB 이름 (예: jangin-prod-alb)"
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  description = "public-a, public-c 서브넷 ID 목록"
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "sg-alb의 ID (기존 flat 리소스 또는 security_group 모듈 출력을 전달)"
  type        = string
}

variable "certificate_arn" {
  description = "ACM 인증서 ARN (acm_alb 모듈 출력, ap-northeast-2)"
  type        = string
}

variable "web_acl_arn" {
  description = "연결할 WAF WebACL ARN (waf 모듈 출력, scope=REGIONAL)"
  type        = string
}

variable "domain_name" {
  description = "이 ALB에 매핑할 도메인 (예: api.midam.store)"
  type        = string
}

variable "zone_id" {
  type = string
}

variable "target_port" {
  type    = number
  default = 8080
}

variable "health_check_path" {
  type    = string
  default = "/healthz"
}

variable "healthy_threshold" {
  type    = number
  default = 2
}

variable "unhealthy_threshold" {
  type    = number
  default = 3
}

variable "health_check_timeout" {
  type    = number
  default = 5
}

variable "health_check_interval" {
  type    = number
  default = 30
}

variable "deregistration_delay" {
  description = "BE graceful shutdown(30s)과 짝을 맞춘 값. 기본 300s 아님에 주의"
  type        = number
  default     = 30
}

variable "idle_timeout" {
  description = <<-EOT
    유휴 연결 유지 시간(초). AWS 기본값은 60 이다.

    🔴 AI 스트리밍(SSE)에서 60초는 짧다. 토큰 사이 간격이 60초를 넘으면
       ALB 가 연결을 끊고, 클라이언트에는 응답 중단으로 보인다.
       GPU 추론은 첫 토큰까지 시간이 길어 특히 걸리기 쉽다.
  EOT
  type        = number
  default     = 60
}
