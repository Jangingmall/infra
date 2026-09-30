variable "project" {
  description = "프로젝트 접두사."
  type        = string
}

variable "env" {
  description = "환경 구분."
  type        = string
}

variable "name_suffix" {
  description = <<-EOT
    같은 계정에 리전별로 두 벌을 만들기 때문에 이름이 겹치지 않게 접미사를 받는다.
    예: "apne2", "use1". SNS 토픽 이름은 리전 단위로 유일하면 되지만,
    로그·태그에서 어느 리전 것인지 구분하려면 이름에 드러나는 편이 낫다.
  EOT
  type        = string
}

variable "alert_emails" {
  description = <<-EOT
    경보를 받을 이메일 주소 목록.

    🔴 SNS 이메일 구독은 apply 만으로 끝나지 않는다. AWS 가 확인 메일을 보내고
       수신자가 링크를 눌러야 PendingConfirmation → Confirmed 로 바뀐다.
       확인하지 않으면 apply 는 성공하지만 알림은 오지 않는다.

    비워 두면 토픽과 규칙만 만들고 구독은 만들지 않는다(나중에 추가 가능).
  EOT
  type        = list(string)
  default     = []
}

variable "rules" {
  description = <<-EOT
    만들 EventBridge 규칙. 키가 규칙 이름 접미사가 된다.

    🔴 소음이 나는 규칙은 넣지 않는다. 보안그룹 변경·노드그룹 변경은
       apply 와 야간 정지마다 발생해서 알림이 무의미해진다.
       "평시에 절대 일어나지 않아야 하는 것"만 고른다.
  EOT
  type = map(object({
    description   = string
    event_pattern = string
  }))
}

variable "tags" {
  description = "추가 태그. provider default_tags 에 더해진다."
  type        = map(string)
  default     = {}
}
