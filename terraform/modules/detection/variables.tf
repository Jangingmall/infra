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

variable "kms_master_key_id" {
  description = <<-EOT
    SNS 토픽 저장 시 암호화에 쓸 KMS 키. 기본은 null — 암호화하지 않는다.

    🔴 "alias/aws/sns"(AWS 관리형 키)를 쓰면 안 된다.
       EventBridge 는 publish 할 때 events.amazonaws.com 서비스 프린시펄로
       kms:GenerateDataKey* 를 호출한다. 그런데 관리형 키의 키 정책은
         Principal { "AWS": "*" }  +  kms:ViaService = sns.<region>.amazonaws.com
       이고 "AWS": "*" 는 IAM 프린시펄만 뜻한다 — 서비스 프린시펄은 포함되지 않는다.
       관리형 키는 키 정책을 수정할 수 없으므로 events 를 추가할 방법도 없다.
       결과: 규칙은 매칭되는데 타깃 호출이 KMSAccessDenied 로 조용히 실패한다.
       (실측: 계정의 alias/aws/sns 키 정책에 events 관련 statement 0 개,
        sns.amazonaws.com 에도 kms:Decrypt 만 있고 GenerateDataKey 는 없다)

    🔑 그래서 선택지는 두 개뿐이다 — 암호화를 빼거나(기본), 리전별 CMK 를 쓰거나.
       CMK 를 넘길 경우 그 키 정책에 다음이 있어야 한다.
         Principal { Service = "events.amazonaws.com" }
         Action    = ["kms:GenerateDataKey*", "kms:Decrypt"]
         Condition  aws:SourceAccount = <계정>
       키는 리전 단위라 서울·버지니아에 각각 필요하다(월 $1/개).

    staging 은 null 로 둔다. 알리는 내용이 CloudTrail 이벤트 요약이고 원본은
    이미 CloudTrail(SSE-KMS)에 있으며, 최종 전달이 이메일 평문이라 토픽만
    암호화해서 얻는 것이 없다. CMK 는 삭제 대기기간이 최소 7일이라
    10/6 종료 체크리스트도 복잡해진다.
  EOT
  type        = string
  default     = null
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
