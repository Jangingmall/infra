# [ECR] 환경 루트에 직접 작성 (자식 모듈 호출 없음)
# 담당: 이창원. IAM push/pull 권한, provider/backend는 각 담당자 소유.
# 공용 저장소의 단일 소유 state 확정 전에는 ecr_enabled=false 유지.
# 두 환경을 동시에 활성화하지 않는다. 활성화 전 기존 레포/state와 lifecycle preview 확인.
# 기본 10개/7일은 입력 초안이며 운영/롤백 digest 자동 보호 정책이 아니다.
# 담당: 이창원(DB&DR / CI·CD)
# 역할: 백엔드·AI 컨테이너 이미지를 저장하는 ECR 레포 생성.
#       태그 불변(immutable) + push 스캔 + lifecycle(보관정책)까지만 담당.
#       push/pull IAM 권한은 IAM 담당(박다정)이 outputs의 repository_arns를 참조해 부여.

locals {
  # 레포별 공통 태그
  ecr_common_tags = merge(
    {
      Project     = "jangin"
      Environment = var.ecr_env
      Owner       = "changwon"
      Component   = "ecr"
      ManagedBy   = "terraform"
    },
    var.ecr_tags,
  )
}

resource "aws_ecr_repository" "app" {
  for_each = var.ecr_enabled ? toset(var.ecr_repositories) : toset([])

  name = each.value

  # 같은 태그 재push 차단 → 커밋 SHA 태그 1:1 보장, latest 덮어쓰기 불가
  image_tag_mutability = "IMMUTABLE"

  # push 시 자동 취약점 스캔
  image_scanning_configuration {
    scan_on_push = true
  }

  # 저장 암호화 (기본 AES256, KMS CMK 지정 시 KMS)
  encryption_configuration {
    encryption_type = var.ecr_kms_key_arn == null ? "AES256" : "KMS"
    kms_key         = var.ecr_kms_key_arn
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
        description  = "expire untagged after ${var.ecr_untagged_expire_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.ecr_untagged_expire_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "keep last ${var.ecr_keep_last_images} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.ecr_keep_last_images
        }
        action = { type = "expire" }
      },
    ]
  })
}
