# 격리된 로컬 테스트 전용. 환경 루트의 provider/backend를 소유하지 않는다.
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
