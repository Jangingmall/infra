mock_provider "aws" {}

variables {
  enabled = true
  env     = "prod"
}

run "defaults_preserve_repository_policy" {
  command = plan
  assert {
    condition     = aws_ecr_repository.app["jangin-app"].image_tag_mutability == "IMMUTABLE" && aws_ecr_repository.app["jangin-app"].image_scanning_configuration[0].scan_on_push && aws_ecr_repository.app["jangin-app"].encryption_configuration[0].encryption_type == "AES256" && jsondecode(aws_ecr_lifecycle_policy.app["jangin-app"].policy).rules[1].selection.countNumber == 10
    error_message = "기존 기본 Immutable/보관 개수 설정이 바뀌면 안 됩니다."
  }
}

run "custom_names_and_counts" {
  command = plan
  variables {
    repositories         = ["team/api", "team/ai__image"]
    keep_last_images     = 25
    untagged_expire_days = 14
    tags                 = { Owner = "test-owner" }
    kms_key_arn          = "arn:aws:kms:ap-northeast-2:111122223333:key/00000000-0000-0000-0000-000000000000"
  }
  assert {
    condition     = length(aws_ecr_repository.app) == 2 && aws_ecr_repository.app["team/api"].tags["Owner"] == "test-owner" && aws_ecr_repository.app["team/api"].encryption_configuration[0].kms_key == var.kms_key_arn && aws_ecr_repository.app["team/api"].encryption_configuration[0].encryption_type == "KMS" && aws_ecr_repository.app["team/api"].name == "team/api" && jsondecode(aws_ecr_lifecycle_policy.app["team/api"].policy).rules[0].selection.countNumber == 14 && jsondecode(aws_ecr_lifecycle_policy.app["team/api"].policy).rules[1].selection.countNumber == 25
    error_message = "입력한 이름/보관기간/개수가 레포 정책에 반영되어야 합니다."
  }
}

run "reject_duplicate_names" {
  command = plan
  variables { repositories = ["jangin-app", "jangin-app"] }
  expect_failures = [var.repositories]
}

run "reject_invalid_name" {
  command = plan
  variables { repositories = ["INVALID NAME"] }
  expect_failures = [var.repositories]
}

run "reject_fractional_count" {
  command = plan
  variables { keep_last_images = 1.5 }
  expect_failures = [var.keep_last_images]
}

run "reject_zero_days" {
  command = plan
  variables { untagged_expire_days = 0 }
  expect_failures = [var.untagged_expire_days]
}

run "disabled_environment_creates_nothing" {
  command = plan
  variables { enabled = false }
  assert {
    condition     = length(aws_ecr_repository.app) == 0 && length(aws_ecr_lifecycle_policy.app) == 0 && length(output.repository_urls) == 0
    error_message = "단일 소유 환경이 정해지기 전에는 리소스를 생성하면 안 됩니다."
  }
}
