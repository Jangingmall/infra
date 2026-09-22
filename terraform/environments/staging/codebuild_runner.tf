# codebuild - GenAI CI 러너 (CodeBuild)

module "codebuild_genai_runner" {
  source = "../../modules/codebuild"

  name            = "jangin-genai-runner"
  github_repo_url = "https://github.com/Jangingmall/GenAI.git"
  connection_arn  = "arn:aws:codeconnections:ap-northeast-2:750240012008:connection/55552edd-3687-4d81-84d1-62846beecc86"

}

output "genai_runner_runs_on" { value = module.codebuild_genai_runner.runs_on_label }
