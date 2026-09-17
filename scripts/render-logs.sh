#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --help && $# -eq 1 ]]; then
  printf '%s\n' 'Usage: bash scripts/render-logs.sh stage|prod OUTPUT_DIRECTORY' 'Render only; no AWS or Kubernetes changes. Requires Helm, kubectl and network access.'
  exit 0
fi
if [[ $# -ne 2 || ! $1 =~ ^(stage|prod)$ ]]; then
  printf '%s\n' 'Usage: bash scripts/render-logs.sh stage|prod OUTPUT_DIRECTORY' >&2
  exit 2
fi
environment="$1"
output="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
logs="$repo_root/platform/observability/logs"
mkdir -p "$output"
charts="$(mktemp -d "${TMPDIR:-/tmp}/janging-log-charts.XXXXXX")"
trap 'rm -rf "$charts"' EXIT
helm pull loki --repo https://grafana.github.io/helm-charts --version 7.3.0 --untar --untardir "$charts"
helm pull alloy --repo https://grafana.github.io/helm-charts --version 1.12.1 --untar --untardir "$charts"
helm lint "$charts/loki" --strict -n monitoring -f "$logs/loki.yaml" -f "$logs/$environment.yaml"
helm template loki "$charts/loki" -n monitoring -f "$logs/loki.yaml" -f "$logs/$environment.yaml" > "$output/loki.yaml"
# chart의 rules sidecar Role에는 Secret 조회도 들어 있다. 실제 사용은 ConfigMap뿐이므로 제거한다.
# 배포 시에도 이 렌더러의 결과를 사용한다. chart를 직접 설치하면 이 보정이 적용되지 않는다.
ruby -ryaml -e '
  docs = YAML.load_stream(File.read(ARGV[0])).compact
  docs.select { |r| r["kind"] == "Role" && r.dig("metadata", "name") == "loki" }.each do |r|
    r["rules"].each { |rule| rule["resources"] -= ["secrets"] }
  end
  File.write(ARGV[0], docs.map(&:to_yaml).join)
' "$output/loki.yaml"
for kind in pods events; do
  # 버퍼 설정을 복제하지 않고 기존 공통 파일을 합쳐 단일 입력으로 사용한다.
  cat "$logs/$kind.alloy" "$repo_root/platform/observability/collectors/log-buffer.alloy" > "$output/$kind.alloy"
  args=(-n monitoring -f "$logs/alloy-$kind.yaml"
    --set-file "alloy.configMap.content=$output/$kind.alloy"
    --set-string "alloy.extraEnv[0].name=OBS_ENV" --set-string "alloy.extraEnv[0].value=$environment"
    --set-string "alloy.extraEnv[1].name=LOKI_PUSH_URL" --set-string 'alloy.extraEnv[1].value=http://loki-gateway.monitoring.svc/loki/api/v1/push')
  helm lint "$charts/alloy" --strict "${args[@]}"
  helm template "alloy-$kind" "$charts/alloy" "${args[@]}" > "$output/alloy-$kind.yaml"
done
kubectl kustomize "$logs/policies" > "$output/policies.yaml"
ruby "$repo_root/scripts/validate-logs.rb" "$environment" "$output"
