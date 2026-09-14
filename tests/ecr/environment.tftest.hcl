# Mock apply resolves computed URL/ARN outputs without contacting AWS.
mock_provider "aws" {
  mock_resource "aws_ecr_repository" {
    defaults = {
      repository_url = "example.invalid/test-repository"
      arn            = "arn:aws:ecr:ap-northeast-2:111122223333:repository/test-repository"
      registry_id    = "111122223333"
    }
  }
}

run "default_environment_is_disabled" {
  command = plan
  assert {
    condition     = length(output.ecr_repository_urls) == 0 && length(output.ecr_repository_arns) == 0 && output.ecr_registry_id == null
    error_message = "환경 기본값은 비활성이며 출력 맵은 비어 있어야 합니다."
  }
}

run "default_repository_outputs" {
  command = apply
  variables { ecr_enabled = true }
  assert {
    condition     = length(output.ecr_repository_urls) == 1 && output.ecr_repository_urls["jangin-app"] == "example.invalid/test-repository" && output.ecr_repository_arns["jangin-app"] == "arn:aws:ecr:ap-northeast-2:111122223333:repository/test-repository" && output.ecr_registry_id == "111122223333"
    error_message = "기본 저장소의 URL/ARN/registry ID가 모듈에서 루트 output으로 전달되어야 합니다."
  }
}

run "custom_repository_outputs" {
  command = apply
  variables {
    ecr_enabled      = true
    ecr_repositories = ["team/api", "team/ai__image"]
  }
  assert {
    condition     = length(output.ecr_repository_urls) == 2 && output.ecr_repository_urls["team/api"] == "example.invalid/test-repository" && output.ecr_repository_arns["team/ai__image"] == "arn:aws:ecr:ap-northeast-2:111122223333:repository/test-repository" && output.ecr_registry_id == "111122223333"
    error_message = "사용자 지정 저장소 목록과 모듈 출력값이 환경 루트를 통해 전달되어야 합니다."
  }
}
