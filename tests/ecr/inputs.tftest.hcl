mock_provider "aws" {}

variables {
  ecr_enabled = true
}

run "defaults_preserve_repository_policy" {
  command = plan
  assert {
    condition     = aws_ecr_repository.app["jangin-app"].image_tag_mutability == "IMMUTABLE" && jsondecode(aws_ecr_lifecycle_policy.app["jangin-app"].policy).rules[1].selection.countNumber == 10
    error_message = "기존 기본 Immutable/보관 개수 설정이 바뀌면 안 됩니다."
  }
}

run "custom_names_and_counts" {
  command = plan
  variables {
    ecr_repositories         = ["team/api", "team/ai__image"]
    ecr_keep_last_images     = 25
    ecr_untagged_expire_days = 14
    ecr_kms_key_arn          = "arn:aws:kms:ap-northeast-2:111122223333:key/00000000-0000-0000-0000-000000000000"
  }
  assert {
    condition     = length(aws_ecr_repository.app) == 2 && aws_ecr_repository.app["team/api"].name == "team/api" && jsondecode(aws_ecr_lifecycle_policy.app["team/api"].policy).rules[0].selection.countNumber == 14 && jsondecode(aws_ecr_lifecycle_policy.app["team/api"].policy).rules[1].selection.countNumber == 25
    error_message = "입력한 이름/보관기간/개수가 레포 정책에 반영되어야 합니다."
  }
}

run "reject_duplicate_names" {
  command = plan
  variables { ecr_repositories = ["jangin-app", "jangin-app"] }
  expect_failures = [var.ecr_repositories]
}

run "reject_invalid_name" {
  command = plan
  variables { ecr_repositories = ["INVALID NAME"] }
  expect_failures = [var.ecr_repositories]
}

run "reject_fractional_count" {
  command = plan
  variables { ecr_keep_last_images = 1.5 }
  expect_failures = [var.ecr_keep_last_images]
}

run "reject_zero_days" {
  command = plan
  variables { ecr_untagged_expire_days = 0 }
  expect_failures = [var.ecr_untagged_expire_days]
}

run "disabled_environment_creates_nothing" {
  command = plan
  variables { ecr_enabled = false }
  assert {
    condition     = length(aws_ecr_repository.app) == 0 && length(aws_ecr_lifecycle_policy.app) == 0 && length(output.ecr_repository_urls) == 0
    error_message = "단일 소유 환경이 정해지기 전에는 리소스를 생성하면 안 됩니다."
  }
}
