# Parameter Store 값은 Backend·AI 담당자가 직접 등록·갱신한다.
# Terraform은 KMS·IRSA만 관리한다. 아래 생성 코드는 참고용으로 비활성화한다.
# 다시 활성화할 때는 기존 파라미터의 소유권·state를 먼저 확인한다.

# resource "aws_ssm_parameter" "backend" {
#   for_each = nonsensitive(toset(keys(var.backend_ssm_parameters)))
#
#   name   = "/${var.env}/backend/${each.key}"
#   type   = "SecureString"
#   key_id = module.kms_app.key_arn
#   value  = var.backend_ssm_parameters[each.key]
# }
#
# resource "aws_ssm_parameter" "ai" {
#   for_each = nonsensitive(toset(keys(var.ai_ssm_parameters)))
#
#   name   = "/${var.env}/ai/${each.key}"
#   type   = "SecureString"
#   key_id = module.kms_app.key_arn
#   value  = var.ai_ssm_parameters[each.key]
# }
