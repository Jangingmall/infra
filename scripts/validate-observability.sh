#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --help && $# -eq 1 ]]; then
  printf '%s\n' 'Usage: bash scripts/validate-observability.sh' 'Lint and render the pinned metrics chart for Stage/Prod. No cluster access.'
  exit 0
fi
if [[ $# -ne 0 ]]; then
  printf '%s\n' 'Usage: bash scripts/validate-observability.sh' >&2
  exit 2
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
metrics_dir="$repo_root/platform/observability/metrics"
validation_dir="$(mktemp -d "${TMPDIR:-/tmp}/janging-metrics-validation.XXXXXX")"
trap 'rm -rf "$validation_dir"' EXIT
helm pull kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts \
  --version 91.4.1 --untar --untardir "$validation_dir" \
  --repository-cache "$validation_dir/cache" --repository-config "$validation_dir/repositories.yaml"
for environment in stage prod; do
  helm lint "$validation_dir/kube-prometheus-stack" --strict --namespace monitoring \
    -f "$metrics_dir/values.yaml" -f "$metrics_dir/$environment.yaml" \
    --set-file "grafana.dashboards.backend.overview.json=$repo_root/platform/observability/backend/dashboard.json" \
    --set-file "grafana.dashboards.gpu.overview.json=$repo_root/platform/observability/gpu/dashboard.json" \
    --set-file "grafana.dashboards.platform.cnpg.json=$repo_root/platform/observability/platform/cnpg-dashboard.json" \
    --set-file "grafana.dashboards.platform.argo.json=$repo_root/platform/observability/platform/argo-dashboard.json"
  helm template metrics "$validation_dir/kube-prometheus-stack" --namespace monitoring \
    -f "$metrics_dir/values.yaml" -f "$metrics_dir/$environment.yaml" \
    --set-file "grafana.dashboards.backend.overview.json=$repo_root/platform/observability/backend/dashboard.json" \
    --set-file "grafana.dashboards.gpu.overview.json=$repo_root/platform/observability/gpu/dashboard.json" \
    --set-file "grafana.dashboards.platform.cnpg.json=$repo_root/platform/observability/platform/cnpg-dashboard.json" \
    --set-file "grafana.dashboards.platform.argo.json=$repo_root/platform/observability/platform/argo-dashboard.json" > "$validation_dir/$environment.yaml"
  printf '\n---\n' >> "$validation_dir/$environment.yaml"
  kubectl kustomize "$repo_root/platform/observability/backend" >> "$validation_dir/$environment.yaml"
  ruby "$repo_root/scripts/validate-observability.rb" "$environment" "$validation_dir/$environment.yaml"
done
bash "$repo_root/scripts/validate-alerting.sh" "$validation_dir/kube-prometheus-stack"
