#!/usr/bin/env bash
# ============================================================
# Terraform State 백엔드 부트스트랩 (S3 + DynamoDB Lock)
#   장인몰 인프라 · 2026-09-12 · 신준한 (클라우드 인프라 서브 파트장)
#
#   이 두 리소스만 CLI로 만들고, 나머지 모든 인프라는
#   이 백엔드를 참조하는 Terraform 코드로 관리합니다.
#
#   멱등성(idempotent): 여러 번 실행해도 안전합니다.
#                       이미 있으면 건너뛰고 설정만 다시 맞춥니다.
# ============================================================
#
# [이 스크립트가 하는 일 6가지]
#
#   1. S3 버킷 생성          → State(장부) 보관함
#   2. Versioning 활성화     → State가 깨졌을 때 유일한 복구 수단
#   3. KMS CMK 생성          → 🔄 09-16 신설. State 전용 고객 관리 키
#   4. 기본 암호화(SSE-KMS)  → State에 리소스 ARN·ID가 그대로 들어감
#   5. Public Access Block   → 보안 요구사항 (다정님 명시)
#   6. 태그 부착             → Cost Explorer 필터링 선행조건 (작업규칙 13)
#   7. DynamoDB Lock 테이블  → 두 사람이 동시에 apply 하는 사고 방지
#
# ============================================================
# [왜 Terraform이 아니라 쉘인가 — 의도적 선택]
#
# Terraform으로도 가능하며(로컬 state → apply → backend 추가 → migrate),
# 코드 가독성과 드리프트 감지 면에서는 그쪽이 우수함.
# (구현 예시는 이 파일 맨 아래에 주석으로 첨부)
#
# 그럼에도 CLI를 택한 이유:
#  1) State 버킷이 Terraform 관리 대상이 되면, 해당 config에서 destroy 시
#     전 환경의 State가 소실 가능. prevent_destroy로 막을 수 있으나
#     "막아야 안전한 구조"보다 "위험이 없는 구조"를 택함
#  2) 로컬 state가 .gitignore에 걸려, migrate를 빠뜨린 팀원이
#     버킷을 중복 생성하려 시도하는 사고가 잦음
#  3) 생성 후 변경이 없는 리소스라 Terraform의 수렴 관리 이점이 미미
#
# 팀 결정 근거: 컨텍스트 A-3 "State: CLI 수동 생성 승인"
#              박다정 회신 A2 "이 두 리소스만 CLI/콘솔로 만들고"
#
# → Phase3 산출물 3번 "구성 관리 자동화 스크립트"로 제출
# ============================================================
set -euo pipefail

# AWS CLI v2는 출력을 기본적으로 페이저(less)에 통과시킵니다.
# 그러면 화면 제어 문자 때문에 출력이 겹쳐 보입니다. 스크립트에서는 끕니다.
export AWS_PAGER=""

# ---------- 설정값 (필요하면 여기만 수정) ----------
REGION="ap-northeast-2"
# CLAUDE.md 「S3 버킷 5종 + State」 표의 확정값을 따릅니다.
BUCKET="jangin-infra-s3-tfstate"         # 🔴 S3 이름은 전 세계에서 유일해야 함
TABLE="jangin-infra-ddb-tfstate-lock"    # 네이밍 규칙 jangin-<env>-<resource> 적용
PROJECT_TAG="jangin"

# 🔄 2026-09-16 신설 — State 전용 KMS CMK 별칭
#   🔴 ⑧ 단계에서 Terraform 이 만드는 CMK 와 "다른 키"여야 합니다. 이유는 아래 3번 참조.
KMS_ALIAS="alias/jangin-infra-s3-tfstate"
# --------------------------------------------------

say() { printf "\n\033[1;36m▶ %s\033[0m\n" "$*"; }
ok()  { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
skip(){ printf "  \033[1;33m·\033[0m %s (이미 있음 — 건너뜀)\n" "$*"; }

# ===== 0. 사전 확인 =====
say "0. 자격증명 확인"
if ! CALLER=$(aws sts get-caller-identity --output json 2>&1); then
  echo "🔴 AWS 자격증명 없음. 아래를 먼저 실행하세요:"
  echo "     export AWS_PROFILE=jangin"
  echo "     aws sso login --profile jangin"
  exit 1
fi
ACCOUNT=$(echo "$CALLER" | python3 -c 'import sys,json;print(json.load(sys.stdin)["Account"])')
ARN=$(echo "$CALLER"     | python3 -c 'import sys,json;print(json.load(sys.stdin)["Arn"])')
ok "계정 ${ACCOUNT}"
ok "역할 ${ARN##*/}"
ok "리전 ${REGION}"
echo
printf "  버킷: %s\n  테이블: %s\n" "$BUCKET" "$TABLE"
printf "\n  이대로 생성할까요? [y/N] "
read -r ANSWER
[[ "$ANSWER" == "y" || "$ANSWER" == "Y" ]] || { echo "중단했습니다."; exit 0; }

# ===== 1. S3 버킷 =====
say "1. S3 버킷 생성"
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  skip "$BUCKET"
else
  aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  ok "생성됨: $BUCKET"
fi

# ===== 2. 버전 관리 =====
# State를 덮어써도 이전 판으로 되돌릴 수 있게 — State 손상 시 유일한 복구 수단
say "2. 버전 관리(Versioning) 활성화"
aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
ok "Enabled"

# ===== 3. KMS CMK (State 전용) =====
# 🔄 2026-09-16 신설 — 파트장(강윤주) 지적 반영.
#    기존에는 SSE-S3(AES256)로 두고 "⑧ KMS 단계에서 전환" TODO 를 달아뒀는데,
#    보안팀 요구사항은 처음부터 SSE-KMS(CMK) 입니다.
#
# ── 왜 ⑧ 을 기다리지 않고 여기서 만드는가 (🔴 순환 의존) ──────────────
#
#   ⑧ 단계의 CMK 는 Terraform 이 만듭니다. 그 키로 State 버킷을 암호화하면
#   "State 를 담은 금고의 열쇠를, 그 State 가 관리하는" 구조가 됩니다.
#
#     terraform destroy (⑧)
#       → KMS 키가 삭제 대기(7~30일)로 들어감
#       → 그 순간부터 State 를 복호화할 수 없음
#       → terraform 자체가 동작 불능. plan 도 destroy 도 못 함.
#       → 🔴 복구 수단 없음
#
#   그래서 State 버킷용 CMK 는 반드시 Terraform 밖(이 스크립트)에서 만들고,
#   ⑧ 의 애플리케이션용 CMK 와는 별개 키로 유지합니다.
#
# 💰 CMK 1개당 월 약 $1 + 요청당 소액. 아래 BucketKeyEnabled 로 요청 수를 줄입니다.
#    비용 산정서 v1.0 미반영 항목이라 다정님께 공유가 필요합니다.
say "3. KMS CMK 확인/생성 (State 전용)"

# 멱등성: 별칭으로 기존 키를 먼저 찾습니다.
#   🔴 aws kms create-key 는 멱등이 아닙니다. 그냥 실행하면 매번 새 키가 생기고
#      쓰지도 않는 키에 매월 $1 씩 붙습니다. 별칭 조회가 이를 막습니다.
KEY_ARN=$(aws kms describe-key --key-id "$KMS_ALIAS" --region "$REGION" \
            --query 'KeyMetadata.Arn' --output text 2>/dev/null || true)

if [[ -n "${KEY_ARN:-}" && "$KEY_ARN" != "None" ]]; then
  skip "$KMS_ALIAS"
else
  # ── 키 정책 ─────────────────────────────────────────────
  # 🔴 KMS 는 IAM 과 달리 "키 정책"이 1차 관문입니다.
  #    키 정책에서 허용하지 않으면, IAM 에서 아무리 권한을 줘도 못 씁니다.
  #    그래서 키 정책을 좁게 쓰면 자기 키에서 스스로 잠기는(lock-out) 사고가 납니다.
  #    AWS 가 권장하는 기본형은 "계정 루트에 위임"입니다 —
  #    이후 누가 쓸지는 IAM 정책(SSO 퍼미션셋)으로 통제합니다.
  KEY_POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EnableIAMPolicies",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${ACCOUNT}:root" },
      "Action": "kms:*",
      "Resource": "*"
    }
  ]
}
JSON
)
  KEY_ID=$(aws kms create-key \
    --region "$REGION" \
    --description "Terraform state encryption (jangin-infra-s3-tfstate). Created by bootstrap-tfstate.sh - NOT managed by Terraform." \
    --key-usage ENCRYPT_DECRYPT \
    --key-spec SYMMETRIC_DEFAULT \
    --policy "$KEY_POLICY" \
    --tags TagKey=Project,TagValue="${PROJECT_TAG}" \
           TagKey=Environment,TagValue=shared \
           TagKey=ManagedBy,TagValue=manual-cli \
           TagKey=Purpose,TagValue=terraform-state \
    --query 'KeyMetadata.KeyId' --output text)

  aws kms create-alias --region "$REGION" \
    --alias-name "$KMS_ALIAS" --target-key-id "$KEY_ID"

  # 연 1회 자동 키 교체. 예전 데이터는 예전 키 자료로 계속 복호화되므로 무중단입니다.
  aws kms enable-key-rotation --region "$REGION" --key-id "$KEY_ID"

  KEY_ARN=$(aws kms describe-key --key-id "$KMS_ALIAS" --region "$REGION" \
              --query 'KeyMetadata.Arn' --output text)
  ok "생성됨: $KMS_ALIAS"
fi

# 🔴 일부 KMS API 는 별칭을 받지 않습니다 (예: get-key-rotation-status).
#    ARN 끝부분이 곧 키 ID 이므로 API 호출 없이 잘라 씁니다.
#      arn:aws:kms:<region>:<account>:key/<KEY_ID>
KEY_ID="${KEY_ARN##*/}"

# ===== 4. 기본 암호화 (SSE-KMS / CMK) =====
say "4. 기본 암호화(SSE-KMS · CMK) 설정"
aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  "{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"aws:kms\",\"KMSMasterKeyID\":\"${KEY_ARN}\"},\"BucketKeyEnabled\":true}]}"
ok "aws:kms + BucketKey (요청 비용 절감)"

# 🔴 여기까지만으로는 "실제로" KMS 로 저장되지 않습니다.
#    Terraform S3 백엔드는 backend.tf 의 encrypt = true 만 있으면
#    PutObject 에 AES256 헤더를 직접 붙여서, 버킷 기본 암호화를 덮어씁니다.
#    → backend.tf 에 kms_key_id 를 같이 넣어야 합니다. (같은 PR 에 포함)
#    → 검증은 아래 8번의 head-object 출력으로 합니다. 버킷 설정이 아니라
#      "객체에 실제로 무엇이 적용됐는지"를 봐야 합니다.

# ===== 5. Public Access Block (다정님 요구사항) =====
say "5. 퍼블릭 접근 차단 (4종 전부)"
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
ok "BlockPublicAcls / IgnorePublicAcls / BlockPublicPolicy / RestrictPublicBuckets"

# ===== 6. 태그 =====
say "6. 태그 부착 (비용 분석 선행조건)"
aws s3api put-bucket-tagging \
  --bucket "$BUCKET" \
  --tagging "TagSet=[{Key=Project,Value=${PROJECT_TAG}},{Key=Environment,Value=shared},{Key=ManagedBy,Value=manual-cli},{Key=Purpose,Value=terraform-state}]"
ok "Project / Environment / ManagedBy / Purpose"

# ===== 6-2. TLS 강제 버킷 정책 (CLAUDE.md 요구) =====
# HTTP(암호화 안 된 평문)로 오는 요청을 전부 거부합니다.
# State 파일에는 리소스 ARN·ID가 그대로 들어가므로 전송 구간 보호가 필요합니다.
# aws:SecureTransport 가 false = HTTPS가 아닌 요청.
say "6-2. TLS 강제 버킷 정책"
POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::${BUCKET}",
        "arn:aws:s3:::${BUCKET}/*"
      ],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } }
    }
  ]
}
JSON
)
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$POLICY"
ok "HTTP 요청 Deny (aws:SecureTransport=false)"

# ===== 7. DynamoDB Lock 테이블 =====
# 두 사람이 동시에 apply 하면 State가 깨집니다. 먼저 온 쪽이 자물쇠를 걸고,
# 나중 쪽은 "누가 작업 중"이라는 메시지를 받고 대기합니다.
say "7. DynamoDB Lock 테이블 생성"
if aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" >/dev/null 2>&1; then
  skip "$TABLE"
else
  aws dynamodb create-table \
    --table-name "$TABLE" \
    --region "$REGION" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --tags Key=Project,Value="${PROJECT_TAG}" Key=Environment,Value=shared \
           Key=ManagedBy,Value=manual-cli Key=Purpose,Value=terraform-state-lock >/dev/null
  printf "  테이블 활성화 대기 중"
  aws dynamodb wait table-exists --table-name "$TABLE" --region "$REGION"
  ok "생성됨: $TABLE"
fi

# ===== 8. 검증 =====
# 🔑 보안팀 검수에 그대로 붙일 수 있는 출력입니다.
#
# 🔴 여기서 set -e 를 잠시 끕니다.
#    위쪽 "생성" 구간은 중간에 실패하면 반쪽짜리 리소스가 남으므로 즉시 중단이 맞지만,
#    "조회" 구간은 정반대입니다. 항목 하나가 실패했다고 나머지를 안 보여주면
#    검증 자체가 무의미해집니다. (09-16 실제 사고: 키 교체 상태 조회 실패로
#    가장 중요한 8-2 객체 암호화 확인이 실행되지 못함)
set +e

say "8. 검증"
printf "  Versioning       : "; aws s3api get-bucket-versioning --bucket "$BUCKET" --query 'Status' --output text
printf "  Encryption(설정) : "; aws s3api get-bucket-encryption --bucket "$BUCKET" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text
printf "  KMS Key Alias    : %s\n" "$KMS_ALIAS"
# ⚠️ 별칭이 아니라 KEY_ID 를 넘깁니다. 이 API 는 별칭을 거부합니다.
printf "  KMS Key Rotation : "; aws kms get-key-rotation-status --region "$REGION" \
  --key-id "$KEY_ID" --query 'KeyRotationEnabled' --output text 2>/dev/null || echo "(조회 실패)"
printf "  BucketKeyEnabled : "; aws s3api get-bucket-encryption --bucket "$BUCKET" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].BucketKeyEnabled' --output text
printf "  PublicAccessBlock: "; aws s3api get-public-access-block --bucket "$BUCKET" \
  --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' --output text
printf "  BucketPolicy(TLS): "; aws s3api get-bucket-policy --bucket "$BUCKET" \
  --query 'Policy' --output text | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["Statement"][0]["Sid"], d["Statement"][0]["Effect"])'
printf "  DynamoDB Status  : "; aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" \
  --query 'Table.TableStatus' --output text

# 🔴 여기가 진짜 검증입니다.
#    위의 "Encryption(설정)"은 버킷의 기본값일 뿐이고,
#    실제 State 객체가 무엇으로 암호화됐는지는 객체를 직접 봐야 압니다.
#    backend.tf 의 kms_key_id 를 빠뜨리면 여기만 AES256 으로 남습니다.
say "8-2. 실제 State 객체 암호화 확인 (가장 중요)"
for K in prod/terraform.tfstate staging/terraform.tfstate; do
  OBJ_SSE=$(aws s3api head-object --bucket "$BUCKET" --key "$K" \
              --query 'ServerSideEncryption' --output text 2>/dev/null || true)
  if [[ -z "${OBJ_SSE:-}" || "$OBJ_SSE" == "None" ]]; then
    printf "  %-28s : (아직 없음 — apply 전이면 정상)\n" "$K"
  elif [[ "$OBJ_SSE" == "aws:kms" ]]; then
    printf "  %-28s : \033[1;32m%s ✓\033[0m\n" "$K" "$OBJ_SSE"
  else
    printf "  %-28s : \033[1;31m%s ← backend.tf 의 kms_key_id 확인 필요\033[0m\n" "$K" "$OBJ_SSE"
  fi
done

# ⚠️ 이미 존재하는 State 객체는 이 스크립트로 재암호화되지 않습니다.
#    S3 의 기본 암호화는 "앞으로 올라오는 객체"에만 적용됩니다.
#    → 다음 apply 때 새 버전이 SSE-KMS 로 기록되고,
#      버전 관리가 켜져 있어 이전 버전은 AES256 인 채로 남습니다.
#    → 이전 버전을 지우면 복구 수단이 사라지므로 지우지 않습니다.
#      "구버전 State 는 SSE-S3" 를 잔여 위험으로 기록하고 프로젝트 종료 시 정리합니다.

set -e  # 검증 끝 — 엄격 모드 복구

cat <<EOF

============================================================
✅ 완료. 다음은 backend.tf 작성입니다.

terraform {
  backend "s3" {
    bucket         = "${BUCKET}"
    key            = "prod/terraform.tfstate"
    region         = "${REGION}"
    dynamodb_table = "${TABLE}"
    encrypt        = true
    kms_key_id     = "${KMS_ALIAS}"
  }
}

🔴 kms_key_id 를 빠뜨리면 버킷 기본 암호화가 무시됩니다.
   encrypt = true 만 있으면 Terraform 이 PutObject 에 AES256 헤더를
   직접 붙이기 때문입니다. 위 8-2 출력이 aws:kms 인지 반드시 확인하세요.

※ 환경 분리는 버킷이 아니라 key 경로로 합니다
   prod    → prod/terraform.tfstate
   staging → staging/terraform.tfstate
============================================================
EOF

# ############################################################################
# ############################################################################
# ##                                                                        ##
# ##   [참고] 동일 구성을 Terraform으로 작성하면 — 전체 주석 (실행 안 됨)     ##
# ##                                                                        ##
# ##   채택하지 않은 안이지만, "몰라서 쉘로 한 게 아니라 알고도 택했다"를     ##
# ##   보여주기 위해 남겨둡니다. 멘토링·발표 Q&A 대비용.                     ##
# ##                                                                        ##
# ############################################################################
# ############################################################################
#
# ── 파일 위치: terraform/bootstrap/main.tf
# ── 🔴 핵심: backend 블록이 "없습니다". 그래서 state가 로컬 파일로 생깁니다.
#           (버킷이 아직 없으니 state를 둘 곳이 없음 — 이게 부트스트랩 문제)
#
# terraform {
#   required_version = ">= 1.5"
#   required_providers {
#     aws = {
#       source  = "hashicorp/aws"
#       version = "~> 5.0"        # ~> 5.0 = 5.x는 허용, 6.0은 불허 (호환성 보호)
#     }
#   }
# }
#
# provider "aws" {
#   region = var.region
#
#   # default_tags: 이 provider로 만드는 모든 리소스에 자동으로 붙는 태그.
#   #               리소스마다 tags를 쓰는 것보다 누락이 없어 실무에서 선호.
#   default_tags {
#     tags = {
#       Project   = "jangin"
#       Env       = "shared"      # prod/staging 공용이라 shared
#       ManagedBy = "terraform"
#       Purpose   = "terraform-state"
#     }
#   }
# }
#
# ── 1. State 버킷 ──────────────────────────────────────────
# resource "aws_s3_bucket" "tfstate" {
#   bucket = var.bucket_name
#
#   lifecycle {
#     prevent_destroy = true
#     # 🔴 이 한 줄이 이 방식의 생명줄입니다.
#     #    없으면 terraform destroy 한 번에 전 환경의 State가 소실됩니다.
#     #    "막아야만 안전한 구조"라는 게 쉘을 택한 첫 번째 이유.
#   }
# }
#
# ── 2. 버전 관리 ──────────────────────────────────────────
# ※ AWS provider 4.x부터 버킷 설정이 개별 리소스로 쪼개졌습니다.
#   (예전엔 aws_s3_bucket 안에 versioning 블록이 있었음 — 옛날 예제 주의)
#
# resource "aws_s3_bucket_versioning" "tfstate" {
#   bucket = aws_s3_bucket.tfstate.id
#   versioning_configuration {
#     status = "Enabled"
#   }
# }
#
# ── 3. 기본 암호화 ────────────────────────────────────────
# resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
#   bucket = aws_s3_bucket.tfstate.id
#   rule {
#     apply_server_side_encryption_by_default {
#       # 🔄 09-16: 실제 구현은 SSE-KMS(CMK)로 전환했습니다(보안팀 요구).
#       #    단, 이 CMK 를 Terraform 이 관리하면 순환 의존이 생깁니다
#       #    — State 를 담은 버킷의 키를 그 State 가 관리하게 되기 때문.
#       #    그래서 실제로는 이 키만 CLI(이 스크립트)로 만듭니다.
#       sse_algorithm     = "aws:kms"
#       kms_master_key_id = aws_kms_key.tfstate.arn
#     }
#     bucket_key_enabled = true    # KMS 요청 비용 절감 (S3 Bucket Keys)
#   }
# }
#
# ── 4. 퍼블릭 접근 차단 ───────────────────────────────────
# resource "aws_s3_bucket_public_access_block" "tfstate" {
#   bucket                  = aws_s3_bucket.tfstate.id
#   block_public_acls       = true   # 퍼블릭 ACL 부착 자체를 거부
#   ignore_public_acls      = true   # 이미 붙은 퍼블릭 ACL을 무시
#   block_public_policy     = true   # 퍼블릭 버킷 정책 부착 거부
#   restrict_public_buckets = true   # 퍼블릭 정책이 있어도 익명 접근 차단
# }
#
# ── 5. DynamoDB Lock ──────────────────────────────────────
# resource "aws_dynamodb_table" "tflock" {
#   name         = var.table_name
#   billing_mode = "PAY_PER_REQUEST"
#   # PAY_PER_REQUEST = 쓴 만큼만 과금. apply 때만 몇 번 읽고 쓰므로 사실상 $0.
#   # PROVISIONED로 하면 안 써도 시간당 고정비가 나갑니다.
#
#   hash_key = "LockID"
#   # 🔴 "LockID"는 Terraform이 고정으로 요구하는 이름입니다. 바꾸면 동작 안 함.
#
#   attribute {
#     name = "LockID"
#     type = "S"     # S = String
#   }
#
#   lifecycle { prevent_destroy = true }
# }
#
# ── 부트스트랩 순서 (이 방식을 쓸 경우) ───────────────────
#
#   1) cd terraform/bootstrap && terraform init
#      → backend 블록이 없으므로 state가 ./terraform.tfstate (로컬)로 생성
#
#   2) terraform plan   → "5 to add, 0 to change, 0 to destroy" 확인
#      terraform apply  → 버킷 + 테이블 생성됨
#
#   3) main.tf에 backend 블록 추가:
#        terraform {
#          backend "s3" {
#            bucket         = "jangin-shared-tfstate-midam"
#            key            = "bootstrap/terraform.tfstate"
#            region         = "ap-northeast-2"
#            dynamodb_table = "jangin-shared-tfstate-lock"
#            encrypt        = true
#          }
#        }
#
#   4) terraform init -migrate-state
#      → "Do you want to copy existing state to the new backend?" → yes
#      → 로컬 state가 방금 만든 버킷 안으로 이사.
#        자기가 만든 금고 안에 자기 장부를 넣는 셈 — 순환처럼 보이지만 정상 동작.
#
#   5) rm terraform.tfstate terraform.tfstate.backup
#      → 로컬 잔여본 제거 (안 지우면 나중에 어느 쪽이 최신인지 헷갈림)
#
#   🔴 4)를 빠뜨리면: 로컬 state가 .gitignore에 걸려 커밋되지 않으므로,
#      레포를 clone한 팀원의 plan이 "버킷을 새로 만들겠다"고 나옵니다.
#      이게 쉘을 택한 두 번째 이유.
#
# ############################################################################
