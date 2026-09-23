# ============================================================
# github_oidc.tf — GitHub Actions OIDC 인증 (prod)
# ------------------------------------------------------------
# 🔴 전제조건: scripts/bootstrap-github-oidc.sh 최초 1회 실행.
#    staging에서 이미 실행했다면 다시 실행할 필요 없음
#    (같은 계정, 같은 Provider를 조회만 하는 구조).
#
# 🔴 GitHub 리포지토리 Settings → Environments → "prod"에
#    Required reviewers 보호 규칙을 반드시 걸어두세요.
#    이 Role은 PowerUserAccess+IAMFullAccess라는 넓은 권한을 가지므로,
#    "prod는 인프라팀 경유" 정책을 여기서 실질적으로 강제하는 지점입니다.
# ============================================================
module "github_oidc" {
  source = "../../modules/github_oidc"

  github_org      = "Jangingmall"
  github_repo     = "infra"
  github_subjects = ["environment:prod"]
  name_suffix     = "prod"

  github_org_id  = "316382159"
  github_repo_id = "1357893008"

  policy_arns = [
    "arn:aws:iam::aws:policy/PowerUserAccess",
    "arn:aws:iam::aws:policy/IAMFullAccess",
  ]
}
output "github_actions_role_arn" { value = module.github_oidc.role_arn }

# ---- Backend 팀 CI (ECR push, main 브랜치만 허용) ----
resource "aws_iam_policy" "gha_backend_ecr" {
  name = "jangin-gha-backend-ecr-push"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload"]
        Resource = "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/jangin-app"
      },
      {
        # build-deploy.yml 의 batch-get-image, promote.yml 의 describe-images 용
        Sid      = "ReadJanginApp"
        Effect   = "Allow"
        Action   = ["ecr:DescribeImages", "ecr:BatchGetImage"]
        Resource = "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/jangin-app"
      }
    ]
  })
}

module "github_oidc_backend" {
  source = "../../modules/github_oidc"

  github_org      = "Jangingmall"
  github_repo     = "backend"
  github_subjects = ["ref:refs/heads/*"]
  name_suffix     = "ci"

  github_org_id  = "316382159"
  github_repo_id = "1353029814"

  policy_arns = [aws_iam_policy.gha_backend_ecr.arn]
}

# ---- GenAI 팀 CI (ECR push, main 브랜치만 허용) ----
resource "aws_iam_policy" "gha_genai_ecr" {
  name = "jangin-gha-genai-ecr-push"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        # 이미지 3개 모두 같은 권한 묶음. push 5개 + 조회 4개.
        # 조회(DescribeImages·BatchGetImage)가 필요한 이유: CI 가 digest 를 Summary 에 출력하고,
        # 같은 커밋 재실행 시 기존 digest 를 재사용하려면 태그를 조회해야 한다 (backend 의 ReadJanginApp 과 같은 이유).
        # 2026-09-23: 저장소 이름 변경(#71) 후 page-generation·chatbot-api 에 조회 권한이 없어
        #             DescribeImages 가 거부됐다. 세 저장소를 한 statement 로 합쳐 재발을 막는다.
        Sid    = "PushPullAiImages"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:DescribeRepositories",
          "ecr:DescribeImages",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = [
          "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/jangin-ai/page-generation",
          "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/jangin-ai/chatbot-api",
          "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/jangin-ai/chatbot-llm",
        ]
      }
    ]
  })
}

# GenAI CI 가 모델 번들을 S3 에 올리기 위한 권한 (2026-09-23 추가)
#
# 범위를 이렇게 좁힌 이유
#   - 버킷 전체가 아니라 모델 번들 prefix 3개에만 객체 권한을 준다.
#     (page-generation/ · chatbot/embedding/ · chatbot/llm/ — ai-model-storage README 138~139행)
#   - s3:DeleteObject 는 주지 않는다. 번들은 "덮어쓰지 않는 버전별 경로"가 규칙이고(README 60·140행),
#     GPU Pod 가 manifest hash 로 그 경로를 고정해 읽는다. CI 가 지우면 실행 중인 Pod 가 깨진다.
#     같은 이유로 워크플로에서 `aws s3 sync --delete` 를 쓰지 않는다.
#   - AbortMultipartUpload·ListMultipartUploadParts 는 대용량 파일이 멀티파트로 올라가기 때문에 필요하다.
#     (이게 없으면 실패한 업로드 조각이 버킷에 남고 CLI 가 정리하지 못한다)
#   - ListBucket 은 버킷 전체에 준다. 조회뿐이고, prefix 조건을 걸면 CLI 호출 형태에 따라 조용히 실패한다.
resource "aws_iam_policy" "gha_genai_models_s3" {
  name = "jangin-gha-genai-models-upload"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListModelsBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:ListBucketMultipartUploads", "s3:GetBucketLocation"]
        Resource = "arn:aws:s3:::${var.project}-${var.env}-s3-models"
      },
      {
        Sid    = "UploadModelBundles"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = [
          "arn:aws:s3:::${var.project}-${var.env}-s3-models/page-generation/*",
          "arn:aws:s3:::${var.project}-${var.env}-s3-models/chatbot/embedding/*",
          "arn:aws:s3:::${var.project}-${var.env}-s3-models/chatbot/llm/*",
        ]
      },
    ]
  })
}

module "github_oidc_genai" {
  source = "../../modules/github_oidc"

  github_org      = "Jangingmall"
  github_repo     = "GenAI"
  github_subjects = ["ref:refs/heads/*"]
  name_suffix     = "ci"

  github_org_id  = "316382159"
  github_repo_id = "1354414273"

  policy_arns = [aws_iam_policy.gha_genai_ecr.arn, aws_iam_policy.gha_genai_models_s3.arn]
}

output "github_actions_role_arn_backend" { value = module.github_oidc_backend.role_arn }
output "github_actions_role_arn_genai" { value = module.github_oidc_genai.role_arn }
