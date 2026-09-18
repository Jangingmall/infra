#!/usr/bin/env bash
set -euo pipefail
if [[ $# -eq 1 && $1 == --help ]]; then
  printf '%s\n' 'Usage: bash scripts/validate-ai-observability.sh' 'Render GPU, opt-in AI metrics and Stage/Prod trace receivers. No EKS access.'
  exit 0
fi
if [[ $# -ne 0 ]]; then
  printf '%s\n' 'Usage: bash scripts/validate-ai-observability.sh' >&2
  exit 2
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validation_dir="$(mktemp -d "${TMPDIR:-/tmp}/janging-ai-observability.XXXXXX")"
trap 'rm -rf "$validation_dir"' EXIT
helm pull dcgm-exporter --repo https://nvidia.github.io/dcgm-exporter/helm-charts \
  --version 4.8.3 --untar --untardir "$validation_dir" \
  --repository-cache "$validation_dir/cache" --repository-config "$validation_dir/repositories.yaml"
helm lint "$validation_dir/dcgm-exporter" --strict --namespace monitoring \
  -f "$repo_root/platform/observability/gpu/values.yaml"
# Stage/Prod는 별도 클러스터지만 GPU 모델/taint/수집 주기는 동일하므로 같은 values를 쓴다.
helm template dcgm-exporter "$validation_dir/dcgm-exporter" --namespace monitoring \
  -f "$repo_root/platform/observability/gpu/values.yaml" > "$validation_dir/gpu.yaml"
kubectl kustomize "$repo_root/platform/observability/gpu/policies" > "$validation_dir/gpu-policies.yaml"
kubectl kustomize "$repo_root/platform/observability/ai-metrics" > "$validation_dir/ai-metrics.yaml"
kubectl kustomize "$repo_root/platform/observability/traces/application-egress" > "$validation_dir/trace-application-egress.yaml"
for environment in stage prod; do
  kubectl kustomize "$repo_root/platform/observability/traces/$environment" > "$validation_dir/traces-$environment.yaml"
done
ruby "$repo_root/scripts/validate-ai-observability.rb" "$validation_dir"
