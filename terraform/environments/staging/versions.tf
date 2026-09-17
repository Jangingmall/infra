# ============================================================
# versions.tf — terraform / provider 버전 고정
# ------------------------------------------------------------
# 역할: 팀원마다 다른 버전으로 plan이 갈리는 것을 막는다.
# ============================================================

terraform {
  # 이 코드를 돌리기 위한 terraform 최소 버전.
  # 1.5 이상을 요구하는 이유: 이 환경에서 쓰는 문법(lifecycle precondition,
  # for_each map 패턴)이 안정적으로 지원되는 하한선이고,
  # CLAUDE.md 기준값이기도 하다.
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source = "hashicorp/aws"

      # "~> 5.0" = 5.x 안에서만 올라간다 (5.99 는 OK, 6.0 은 안 받음).
      # 즉 이건 "범위"일 뿐이고, 실제로 버전을 못 박는 것은
      # .terraform.lock.hcl 파일이다. 그래서 lock 파일을 커밋한다.
      version = "~> 5.0"
    }
  }
}

# 참고: backend 설정은 backend.tf 에 따로 뒀다.
# terraform { } 블록은 여러 파일에 나눠 써도 합쳐지지만,
# backend 블록은 전체에서 딱 1번만 선언할 수 있다.
