#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --help && $# -eq 1 ]]; then
  printf '%s\n' 'Usage: bash scripts/validate-observability.sh' 'Render the actual Stage/Prod metrics Applications and validate alerting. No cluster access.'
  exit 0
fi
if [[ $# -ne 0 ]]; then
  printf '%s\n' 'Usage: bash scripts/validate-observability.sh' >&2
  exit 2
fi
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/janging-metrics-validation.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export OBSERVABILITY_CHART_CACHE="${OBSERVABILITY_CHART_CACHE:-$work/charts}"
for environment in stage prod; do
  ruby "$root/scripts/render-observability.rb" "$environment" "$work/$environment" metrics targets
  cat "$work/$environment/metrics.yaml" "$work/$environment/targets.yaml" > "$work/$environment.yaml"
  ruby "$root/scripts/validate-observability.rb" "$environment" "$work/$environment.yaml"
done
bash "$root/scripts/validate-alerting.sh" "$OBSERVABILITY_CHART_CACHE/kube-prometheus-stack-91.4.1/kube-prometheus-stack"
