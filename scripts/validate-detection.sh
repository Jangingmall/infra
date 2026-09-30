#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --help ]]; then
  printf '%s
'     'Usage: bash scripts/validate-detection.sh'     'Validate EventBridge patterns in terraform/environments/staging/detection/patterns'     'against the sample events in detection/tests using AWS TestEventPattern.'     ''     'Each <rule>.json needs at least one of each fixture:'     '  tests/<rule>.match*.json    must match'     '  tests/<rule>.nomatch*.json  must NOT match'     ''     'NOTE: unlike the other validate-* scripts this one DOES call AWS'     '      (events:TestEventPattern, read-only, no cost). Credentials required.'
  exit 0
fi
if [[ $# -gt 0 ]]; then
  printf '%s
' 'No arguments expected. See --help.' >&2
  exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base="$root/terraform/environments/staging/detection"
pat_dir="$base/patterns"
test_dir="$base/tests"

[[ -d $pat_dir ]] || { printf '%s
' "missing $pat_dir" >&2; exit 2; }

pass=0
fail=0

check() {  # check <pattern-file> <event-file> <expected true|false> <label>
  # AWS 는 Result 를 True/False(대문자)로 돌려준다. 소문자로 정규화해 비교한다.
  local pf=$1 ef=$2 want=$3 label=$4 got
  got=$(aws events test-event-pattern           --event-pattern "file://$pf"           --event "file://$ef"           --query Result --output text 2>&1 | tr '[:upper:]' '[:lower:]') || {
    printf '  FAIL %-46s TestEventPattern 호출 실패: %s
' "$label" "$got"
    fail=$((fail + 1)); return
  }
  if [[ $got == "$want" ]]; then
    printf '  ok   %-46s Result=%s
' "$label" "$got"
    pass=$((pass + 1))
  else
    printf '  FAIL %-46s Result=%s (기대 %s)
' "$label" "$got" "$want"
    fail=$((fail + 1))
  fi
}

for pf in "$pat_dir"/*.json; do
  rule=$(basename "$pf" .json)

  # 패턴 자체가 올바른 JSON 인지 먼저 본다
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$pf" || {
    printf '  FAIL %-46s 패턴이 올바른 JSON 이 아닙니다
' "$rule"
    fail=$((fail + 1)); continue
  }

  # 픽스처는 규칙마다 여러 개 둘 수 있다.
  #   <rule>.match.json      <rule>.match-<이름>.json     걸려야 함
  #   <rule>.nomatch.json    <rule>.nomatch-<이름>.json   걸리면 안 됨
  # root-activity 처럼 리전에 따라 들어오는 이벤트 모양이 다른 규칙은
  # 케이스 하나로 부족하다. 접두사가 리터럴이라 match 글롭이 nomatch 를 잡지 않는다.
  shopt -s nullglob
  ms=("$test_dir/$rule.match"*.json)
  ns=("$test_dir/$rule.nomatch"*.json)
  shopt -u nullglob

  if [[ ${#ms[@]} -eq 0 || ${#ns[@]} -eq 0 ]]; then
    printf '  FAIL %-46s 테스트 픽스처가 없습니다 (match*/nomatch* 각각 최소 1개 필요)
' "$rule"
    fail=$((fail + 1)); continue
  fi

  for m in "${ms[@]}"; do
    check "$pf" "$m" true "$(basename "$m" .json) (걸려야 함)"
  done
  for n in "${ns[@]}"; do
    check "$pf" "$n" false "$(basename "$n" .json) (걸리면 안 됨)"
  done
done

printf '
  통과 %d · 실패 %d
' "$pass" "$fail"
[[ $fail -eq 0 ]] || exit 1
