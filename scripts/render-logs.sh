#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --help && $# -eq 1 ]]; then
  printf '%s\n' 'Usage: bash scripts/render-logs.sh stage|prod OUTPUT_DIRECTORY' 'Render the actual Argo CD log sources only. No AWS or Kubernetes changes.'
  exit 0
fi
if [[ $# -ne 2 || ! $1 =~ ^(stage|prod)$ ]]; then
  printf '%s\n' 'Usage: bash scripts/render-logs.sh stage|prod OUTPUT_DIRECTORY' >&2
  exit 2
fi
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ruby "$root/scripts/render-observability.rb" "$1" "$2" loki alloy-pods alloy-events
kubectl kustomize "$root/platform/observability/logs/policies" > "$2/policies.yaml"
ruby "$root/scripts/validate-logs.rb" "$1" "$2"
