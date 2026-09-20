# ssm.tf — Parameter Store (task ⑧)
# 경로는 irsa.tf의 GetParameter Resource 패턴과 정확히 일치해야 한다.
# key_id는 #46(SSE-KMS 모듈)에서 만드는 CMK를 그대로 참조한다.

resource "aws_ssm_parameter" "backend" {
  for_each = nonsensitive(toset(keys(var.backend_ssm_parameters)))

  name   = "/${var.env}/backend/${each.key}"
  type   = "SecureString"
  key_id = module.kms_app.key_arn
  value  = var.backend_ssm_parameters[each.key]
}

resource "aws_ssm_parameter" "ai" {
  for_each = nonsensitive(toset(keys(var.ai_ssm_parameters)))

  name   = "/${var.env}/ai/${each.key}"
  type   = "SecureString"
  key_id = module.kms_app.key_arn
  value  = var.ai_ssm_parameters[each.key]
}