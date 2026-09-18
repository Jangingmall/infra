#!/bin/sh
set -eu
password=$(cat /mnt/redis-secrets/password)
# SSM 계약: openssl rand -hex 32로 생성한 64자리 hex, 개행 없이 저장한다.
# 평문을 명령 인자/로그/ConfigMap에 넣지 않고 메모리 볼륨 ACL에 SHA-256만 기록한다.
case "$password" in *[!a-fA-F0-9]*|'') echo 'Invalid Redis password file' >&2; exit 1;; esac
[ "${#password}" -eq 64 ] || { echo 'Redis password must be 64 hex characters' >&2; exit 1; }
hash=$(printf '%s' "$password" | sha256sum | cut -d ' ' -f 1)
umask 077
printf 'user default on #%s ~* &* +@all -config -flushall -flushdb -shutdown -module -debug -acl\n' "$hash" > /run/redis/users.acl
unset password hash
exec redis-server /etc/redis/redis.conf --aclfile /run/redis/users.acl
