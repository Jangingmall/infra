#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --help ]]; then
  echo 'Usage: bash scripts/verify-redis.sh'
  echo 'Local Docker-only Redis authentication, Lua token operation and AOF restart check. No AWS/EKS.'
  exit 0
fi
[[ $# == 0 ]] || { echo 'No arguments supported' >&2; exit 2; }
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
qa_dir="$(mktemp -d "${TMPDIR:-/tmp}/redis-qa.XXXXXX")"
name="janging-redis-qa-$$"
volume="${name}-data"
image=redis:7.4.11-bookworm
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
  rm -rf "$qa_dir"
}
trap cleanup EXIT
mkdir -p "$qa_dir/secrets" "$qa_dir/empty" "$qa_dir/missing"
printf '%064d' 1 > "$qa_dir/secrets/password"
: > "$qa_dir/empty/password"
chmod -R a+rX "$qa_dir"
docker volume create "$volume" >/dev/null
docker run --rm --network none --user 0 --entrypoint sh -v "$volume:/data" "$image" -c 'chown 999:999 /data'
args=(--network none --user 999:999 --read-only --cap-drop ALL --security-opt no-new-privileges
  --tmpfs /run/redis:rw,noexec,nosuid,size=1m,uid=999,gid=999
  -v "$repo_root/k8s/base/redis:/etc/redis:ro" -v "$volume:/data" --entrypoint /bin/sh)
docker run -d --name "$name" "${args[@]}" -v "$qa_dir/secrets:/mnt/redis-secrets:ro" "$image" /etc/redis/start.sh >/dev/null
ready() {
  for ((i=0;i<30;i++)); do
    if docker exec "$name" /bin/sh /etc/redis/health.sh >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  docker logs "$name" >&2
  return 1
}
ready
[[ $(docker exec "$name" redis-cli ping) == *NOAUTH* ]]
[[ $(docker exec -e REDISCLI_AUTH=incorrect "$name" redis-cli --no-auth-warning ping 2>&1) == *WRONGPASS* ]]
docker exec "$name" sh -eu -c '
  export REDISCLI_AUTH="$(cat /mnt/redis-secrets/password)"
  test "$(redis-cli --no-auth-warning set qa:token persistent-token EX 300)" = OK
  test "$(redis-cli --no-auth-warning get qa:token)" = persistent-token
  test "$(redis-cli --no-auth-warning eval "return redis.call(\"INCR\",KEYS[1])" 1 qa:rate)" = 1
  case "$(redis-cli --no-auth-warning config get requirepass)" in *NOPERM*) ;; *) exit 1;; esac
'
docker restart --time 15 "$name" >/dev/null
ready
docker exec "$name" sh -eu -c '
  export REDISCLI_AUTH="$(cat /mnt/redis-secrets/password)"
  test "$(redis-cli --no-auth-warning getdel qa:token)" = persistent-token
  test "$(redis-cli --no-auth-warning exists qa:token)" = 0
'
for fixture in empty missing; do
  if docker run --rm "${args[@]}" -v "$qa_dir/$fixture:/mnt/redis-secrets:ro" "$image" /etc/redis/start.sh > "$qa_dir/$fixture.log" 2>&1; then
    echo "$fixture password unexpectedly accepted" >&2; exit 1
  fi
done
if docker logs "$name" 2>&1 | grep -Fq "$(cat "$qa_dir/secrets/password")"; then
  echo 'Password found in container log' >&2; exit 1
fi
printf 'Redis non-root/read-only startup, auth rejection, Lua, AOF restart, GETDEL, admin denial, empty/missing secret and no secret logging PASS\n'
