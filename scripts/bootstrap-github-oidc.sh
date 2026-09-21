#!/bin/bash
# ============================================================
# bootstrap-github-oidc.sh — GitHub Actions OIDC Provider 생성
# ------------------------------------------------------------
# 무엇을 하는 스크립트인가:
#   GitHub Actions가 AWS에 접근할 때 쓰는 OIDC Identity Provider를
#   IAM에 등록합니다. 이 Provider는 계정 전체에서 단 하나만
#   존재해야 하는 리소스입니다.
#
# 왜 Terraform이 아니라 여기서 만드는가:
#   staging/prod가 서로 다른 state를 쓰는 구조라, 양쪽 다
#   Terraform으로 이 리소스를 만들면 먼저 apply한 쪽만 성공하고
#   나머지는 "이미 존재함" 에러로 실패합니다.
#   bootstrap-tfstate.sh(state 버킷·락 테이블)와 같은 이유로
#   Terraform 관리 밖에 둡니다. (성격은 다름 — 저건 순환참조
#   방지용, 이건 중복생성 방지용)
#
# 🔴 실행 시점: environments/staging 또는 environments/prod의
#    github_oidc 모듈을 처음 apply하기 *전에*, 계정당 딱 1회만
#    실행합니다. 모듈이 이 Provider를 data source로 조회하므로,
#    먼저 존재해야 어느 쪽이든 apply가 성공합니다.
#
# 안전하게 재실행 가능:
#   이미 생성되어 있으면 아무 것도 하지 않고 건너뜁니다.
# ============================================================
set -e

if aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?contains(Arn, 'token.actions.githubusercontent.com')]" \
  --output text | grep -q .; then
  echo "이미 존재합니다. 건너뜁니다."
  exit 0
fi

THUMBPRINT=$(echo | openssl s_client -servername token.actions.githubusercontent.com \
  -showcerts -connect token.actions.githubusercontent.com:443 2>/dev/null \
  | openssl x509 -fingerprint -sha1 -noout | sed 's/.*=//;s/://g' | tr 'A-Z' 'a-z')

aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list $THUMBPRINT

echo "생성 완료."