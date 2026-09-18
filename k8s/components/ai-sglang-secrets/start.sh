#!/bin/sh
set -eu
# 현재 AI 이미지는 *_FILE을 읽지 않는다. CSI 파일을 환경변수로 읽고 원래 entrypoint를 실행한다.
# 토큰 내용은 출력하거나 명령으로 평가하지 않는다. 갱신된 토큰 반영에는 Pod 재시작이 필요하다.
BACKEND_AUTH_TOKEN="$(cat /mnt/ai-secrets/backend-auth-token)"
AI_INTERNAL_AUTH_TOKEN="$(cat /mnt/ai-secrets/ai-internal-auth-token)"
: "${BACKEND_AUTH_TOKEN:?backend callback token is empty}"
: "${AI_INTERNAL_AUTH_TOKEN:?AI inbound token is empty}"
export BACKEND_AUTH_TOKEN AI_INTERNAL_AUTH_TOKEN
exec /usr/local/bin/detail-page-ai-entrypoint
