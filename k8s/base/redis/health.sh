#!/bin/sh
set -eu
# -a 인자로 비밀번호를 노출하지 않는다. CSI 교체 후 Redis/Backend 재시작이 필요하다.
export REDISCLI_AUTH="$(cat /mnt/redis-secrets/password)"
[ "$(redis-cli --no-auth-warning ping)" = PONG ]
