# [codebuild] 모듈 출력 값

output "project_name" {
  description = "CodeBuild 프로젝트 이름"
  value       = aws_codebuild_project.this.name
}

output "runs_on_label" {
  description = "워크플로 runs-on 에 넣을 값"
  value       = "codebuild-${aws_codebuild_project.this.name}-$${{ github.run_id }}-$${{ github.run_attempt }}"
}

output "role_arn" {
  description = "CodeBuild 서비스 역할 ARN"
  value       = aws_iam_role.this.arn
}
