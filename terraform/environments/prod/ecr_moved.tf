# 기존 평면 구성으로 관리하던 리소스가 있다면 동일 state에서 주소만 이전한다.
# state 간 이전이나 이름 변경을 처리하는 블록은 아니다.
moved {
  from = aws_ecr_repository.app
  to   = module.ecr.aws_ecr_repository.app
}

moved {
  from = aws_ecr_lifecycle_policy.app
  to   = module.ecr.aws_ecr_lifecycle_policy.app
}
