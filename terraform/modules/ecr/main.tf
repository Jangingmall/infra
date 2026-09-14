# 공용 ECR 리소스. provider/backend는 호출 환경에서 관리한다.
locals {
  # 레포별 공통 태그
  ecr_common_tags = merge(
    {
      Project     = "jangin"
      Environment = var.env
      Owner       = "changwon"
      Component   = "ecr"
      ManagedBy   = "terraform"
    },
    var.tags,
  )
}

resource "aws_ecr_repository" "app" {
  for_each = var.enabled ? toset(var.repositories) : toset([])

  name = each.value

  # 같은 태그 재push 차단 → 커밋 SHA 태그 1:1 보장, latest 덮어쓰기 불가
  image_tag_mutability = "IMMUTABLE"

  # push 시 자동 취약점 스캔
  image_scanning_configuration {
    scan_on_push = true
  }

  # 저장 암호화 (기본 AES256, KMS CMK 지정 시 KMS)
  encryption_configuration {
    encryption_type = var.kms_key_arn == null ? "AES256" : "KMS"
    kms_key         = var.kms_key_arn
  }

  tags = merge(local.ecr_common_tags, { Name = each.value })
}

# lifecycle: untagged 기간 규칙 + 전체 이미지(any) 개수 규칙. 실행 중 이미지 보호 정책은 아님.
resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name

  # AWS lifecycle evaluator가 우선순위를 적용. any 규칙은 마지막 우선순위로 유지.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "expire untagged after ${var.untagged_expire_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expire_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "keep last ${var.keep_last_images} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.keep_last_images
        }
        action = { type = "expire" }
      },
    ]
  })
}
