# ============================================================
# backend.tf — State 원격 저장 + 동시 작업 잠금  (staging)
# ------------------------------------------------------------
# 🔑 prod/backend.tf 와 "key 한 줄"만 다릅니다.
#    버킷·Lock 테이블·KMS 키는 prod 와 공유하고, 환경 격리는 key 경로로 합니다.
#    (CLAUDE.md 「환경 분리 전략」 — 버킷을 나누지 않는 것이 확정값)
#
# 🔴 작업 규칙 14: prod/backend.tf 를 고치면 이 파일도 같이 고쳐야 합니다.
#    동기화 확인:
#      diff terraform/environments/prod/backend.tf \
#           terraform/environments/staging/backend.tf
#    기대 diff: key 한 줄 + 이 헤더 주석뿐
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
    #
    # 🔴 이 한 줄이 prod 와 다른 유일한 값이다. prod 것을 복사해 오면서
    #    이 줄을 안 바꾸면 staging apply 가 prod State 를 덮어쓴다.
    key = "staging/terraform.tfstate"

    region = "ap-northeast-2"

    # 동시 작업 잠금용 DynamoDB 테이블.
    # 두 사람이 같이 apply 하면 State가 깨지므로, 먼저 들어온
    # 사람이 이 테이블에 잠금을 걸고 나머지는 대기한다.
    # (테이블 키는 LockID — 이미 생성돼 있음)
    dynamodb_table = "jangin-infra-ddb-tfstate-lock"

    # State를 S3에 암호화해서 저장
    encrypt = true

    # 🔴 2026-09-16 신설 — 이 한 줄이 없으면 위 encrypt = true 가
    #    버킷의 기본 암호화(SSE-KMS)를 "덮어씁니다".
    #
    #    Terraform S3 백엔드는 encrypt = true 만 있고 kms_key_id 가 없으면
    #    PutObject 요청에 AES256(SSE-S3) 헤더를 직접 붙입니다.
    #    S3 의 버킷 기본 암호화는 "요청에 암호화 지정이 없을 때"만 적용되므로,
    #    버킷을 SSE-KMS 로 바꿔도 State 객체만 계속 AES256 으로 저장됩니다.
    #    → 설정은 KMS 인데 실물은 SSE-S3 인, 가장 발견하기 어려운 형태의 불일치.
    #
    #    검증은 버킷 설정이 아니라 객체를 봐야 합니다:
    #      aws s3api head-object --bucket jangin-infra-s3-tfstate \
    #        --key staging/terraform.tfstate --query ServerSideEncryption
    #      → "aws:kms" 가 나와야 정상
    #
    #    ⚠️ 키 ARN 대신 별칭(alias)을 씁니다. ARN 에는 계정 ID 가 들어가는데
    #       작업 규칙 2 가 계정 ID 의 코드 하드코딩을 금지하기 때문입니다.
    #       이 키는 scripts/bootstrap-tfstate.sh 가 CLI 로 만듭니다
    #       (Terraform 이 관리하면 순환 의존이 생김 — 스크립트 3번 주석 참조).
    kms_key_id = "alias/jangin-infra-s3-tfstate"
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
