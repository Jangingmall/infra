terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # WORKFLOW_JOB_QUEUED 웹훅 필터가 안정적으로 지원되는 하한선
      version = ">= 5.59, < 6.0"
    }
  }
}
