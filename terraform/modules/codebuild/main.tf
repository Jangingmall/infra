# [codebuild] GitHub Actions 러너용 CodeBuild

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  log_group_name = "/aws/codebuild/${var.name}"
}

# 로그 그룹 (보존 기간 제어를 위해 직접 생성)
resource "aws_cloudwatch_log_group" "this" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
}

# CodeBuild 서비스 역할
resource "aws_iam_role" "this" {
  name = "${var.name}-codebuild"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "this" {
  name = "${var.name}-codebuild-base"
  role = aws_iam_role.this.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteBuildLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.this.arn}:*"
      },
      {
        # 서비스 prefix가 codestar-connections → codeconnections 로 바뀌는 중이라 둘 다 허용
        Sid    = "UseGitHubConnection"
        Effect = "Allow"
        Action = [
          "codeconnections:GetConnection",
          "codeconnections:GetConnectionToken",
          "codeconnections:UseConnection",
          "codestar-connections:GetConnection",
          "codestar-connections:GetConnectionToken",
          "codestar-connections:UseConnection",
        ]
        Resource = [
          var.connection_arn,
          replace(var.connection_arn, ":codeconnections:", ":codestar-connections:"),
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "extra" {
  for_each   = toset(var.extra_policy_arns)
  role       = aws_iam_role.this.name
  policy_arn = each.value
}

# CodeBuild 프로젝트
resource "aws_codebuild_project" "this" {
  name          = var.name
  description   = "GitHub Actions self-hosted runner (${var.github_repo_url})"
  service_role  = aws_iam_role.this.arn
  build_timeout = var.build_timeout_minutes

  # 결과물은 워크플로가 ECR에 직접 push → 산출물 없음
  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = var.compute_type
    image                       = var.image
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    # docker build 에 필수. 없으면 Docker 데몬 뜨지 않음
    privileged_mode = true
  }

  source {
    type            = "GITHUB"
    location        = var.github_repo_url
    git_clone_depth = 1

    auth {
      type     = "CODECONNECTIONS"
      resource = var.connection_arn
    }
  }

  logs_config {
    cloudwatch_logs {
      status     = "ENABLED"
      group_name = aws_cloudwatch_log_group.this.name
    }
  }

  depends_on = [aws_iam_role_policy.this]
}

# 웹훅: GitHub Actions 잡 대기열 이벤트만 받음
resource "aws_codebuild_webhook" "this" {
  project_name = aws_codebuild_project.this.name
  build_type   = "BUILD"

  filter_group {
    filter {
      type    = "EVENT"
      pattern = "WORKFLOW_JOB_QUEUED"
    }
  }
}
