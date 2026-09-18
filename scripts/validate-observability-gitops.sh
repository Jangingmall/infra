#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --help && $# -eq 1 ]]; then
  printf '%s\n' 'Usage: bash scripts/validate-observability-gitops.sh' 'Render Stage/Prod observability Applications, including the opt-in Discord wiring. No deployment.'
  exit 0
fi
if [[ $# -ne 0 ]]; then
  printf '%s\n' 'Usage: bash scripts/validate-observability-gitops.sh' >&2
  exit 2
fi
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/janging-observability-gitops.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export OBSERVABILITY_CHART_CACHE="${OBSERVABILITY_CHART_CACHE:-$work/charts}"
for environment in stage prod; do
  ruby "$root/scripts/render-observability.rb" "$environment" "$work/$environment"
  cat "$work/$environment/metrics.yaml" "$work/$environment/targets.yaml" > "$work/$environment-metrics.yaml"
  ruby "$root/scripts/validate-observability.rb" "$environment" "$work/$environment-metrics.yaml"
  ruby "$root/scripts/validate-logs.rb" "$environment" "$work/$environment"
  ruby "$root/scripts/render-observability.rb" "$environment" "$work/discord-$environment" --discord metrics
  ruby "$root/scripts/validate-alerting.rb" "$environment" "$work/discord-$environment/metrics.yaml" "$work"
done
cp "$work/stage/gpu.yaml" "$work/gpu.yaml"
cp "$work/stage/ai-metrics.yaml" "$work/ai-metrics.yaml"
cp "$work/stage/traces.yaml" "$work/traces-stage.yaml"
cp "$work/prod/traces.yaml" "$work/traces-prod.yaml"
kubectl kustomize "$root/platform/observability/gpu/policies" > "$work/gpu-policies.yaml"
kubectl kustomize "$root/platform/observability/traces/application-egress" > "$work/trace-application-egress.yaml"
ruby "$root/scripts/validate-ai-observability.rb" "$work"
bash "$root/scripts/validate-alerting.sh" "$OBSERVABILITY_CHART_CACHE/kube-prometheus-stack-91.4.1/kube-prometheus-stack"
printf '\nObservability Argo CD source validation passed.\n'
