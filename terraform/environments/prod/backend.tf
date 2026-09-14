# ============================================================
# backend.tf — State 원격 저장 + 동시 작업 잠금
# ------------------------------------------------------------
# 역할: terraform이 "무엇을 만들었는지" 기록한 State 파일을
#       내 노트북이 아니라 팀 공용 S3에 둔다.
#
# 왜 필요한가:
#   State가 로컬에만 있으면 → 다른 팀원의 terraform은 리소스가
#   없다고 판단해 같은 VPC를 또 만들려 한다. 또 내 노트북이
#   죽으면 "이미 만든 리소스를 terraform이 못 찾는" 상태가 된다.
# ============================================================

terraform {
  backend "s3" {
    # State 파일을 담는 버킷 (CLAUDE.md 「S3 버킷 5종 + State」 확정값)
    bucket = "jangin-infra-s3-tfstate"

    # 버킷 안에서의 경로. 환경별로 prefix를 나눈다.
    #   prod    → prod/terraform.tfstate
    #   staging → staging/terraform.tfstate
    # 이 분리가 환경 격리의 마지막 방어선이다. State가 섞이면
    # 한쪽 apply가 다른 환경 리소스를 지울 수 있다.
    key = "prod/terraform.tfstate"

    region = "ap-northeast-2"

    # 동시 작업 잠금용 DynamoDB 테이블.
    # 두 사람이 같이 apply 하면 State가 깨지므로, 먼저 들어온
    # 사람이 이 테이블에 잠금을 걸고 나머지는 대기한다.
    # (테이블 키는 LockID — 이미 생성돼 있음)
    dynamodb_table = "jangin-infra-ddb-tfstate-lock"

    # State를 S3에 암호화해서 저장
    encrypt = true
  }
}

# 🔴 여기에 var.region 같은 변수를 쓸 수 없다.
#    terraform은 변수를 읽기 "전"에 backend를 먼저 초기화한다.
#    그래서 이 파일만 값이 리터럴이고, variables.tf 의 region 과
#    값이 중복되는 것도 정상이다.
#
# 참고: dynamodb_table 은 최신 terraform에서 use_lockfile 로 대체가
#       권고되는 중이다. init 시 deprecation 경고가 떠도 동작에는
#       지장이 없고, 팀원이 구버전 terraform을 쓸 수 있으므로
#       이번 단계에서는 바꾸지 않는다.
