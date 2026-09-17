#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --help ]]; then
  printf '%s\n' 'Usage: bash scripts/validate-alerting.sh [pinned-chart-directory]' 'Render Stage/Prod; run promtool/amtool locally. Never contacts AWS or Discord.'
  exit 0
fi
if [[ $# -gt 1 || ( $# -eq 1 && ! -f "$1/Chart.yaml" ) ]]; then
  printf '%s\n' 'Expected an existing kube-prometheus-stack chart directory, or no arguments.' >&2
  exit 2
fi
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/janging-alert-validation.XXXXXX")"
trap 'rm -rf "$work"' EXIT
chart=${1:-}
if [[ -z "$chart" ]]; then
  helm pull kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts --version 91.4.1 \
    --untar --untardir "$work" --repository-cache "$work/cache" --repository-config "$work/repos.yaml"
  chart="$work/kube-prometheus-stack"
fi
alerts="$root/platform/observability/alerts"
# CI의 mktemp(0700)를 읽을 수 있도록 검사 컨테이너는 실행 사용자의 UID/GID를 사용한다.
# 로컬 테스트용 URL만 사용한다. 실제 Webhook을 CI에 전달하지 않는다.
printf '%s\n' 'http://127.0.0.1:9/not-sent' > "$work/discord-webhook-url"
kubectl kustomize "$alerts/rules" > "$work/rule-resource.yaml"
ruby -ryaml -e 'd=YAML.load_file(ARGV[0]); abort "Rule selector missing" unless d.dig("metadata","labels","release")=="metrics" && d.dig("metadata","namespace")=="monitoring"; File.write(ARGV[1], d.fetch("spec").to_yaml)' "$work/rule-resource.yaml" "$work/rules.yaml"
cp "$alerts/tests/rules.test.yaml" "$work/rules.test.yaml"
docker run --rm --user "$(id -u):$(id -g)" --network none -v "$work:/work:ro" -w /work --entrypoint /bin/promtool \
  prom/prometheus:v3.14.0-distroless check rules rules.yaml
docker run --rm --user "$(id -u):$(id -g)" --network none -v "$work:/work:ro" -w /work --entrypoint /bin/promtool \
  prom/prometheus:v3.14.0-distroless test rules rules.test.yaml
for environment in stage prod; do
  helm template metrics "$chart" --namespace monitoring \
    -f "$root/platform/observability/metrics/values.yaml" -f "$root/platform/observability/metrics/$environment.yaml" \
    -f "$alerts/discord/values.yaml" -f "$alerts/discord/$environment/values.yaml" > "$work/$environment.yaml"
  printf '\n---\n' >> "$work/$environment.yaml"
  kubectl kustomize "$alerts/discord/$environment" >> "$work/$environment.yaml"
  ruby "$root/scripts/validate-alerting.rb" "$environment" "$work/$environment.yaml" "$work"
  docker run --rm --user "$(id -u):$(id -g)" --network none -v "$work:/work:ro" -v "$work:/etc/alertmanager/config:ro" \
    -v "$work:/mnt/alertmanager-secrets:ro" --entrypoint /bin/amtool \
    quay.io/prometheus/alertmanager:v0.34.0 check-config "/work/$environment-alertmanager.yaml"
  # 다른 환경, environment 누락, 승인하지 않은 기본 경보는 외부로 전송하지 않는다.
  am_route() {
    docker run --rm --user "$(id -u):$(id -g)" --network none -v "$work:/work:ro" --entrypoint /bin/amtool \
      quay.io/prometheus/alertmanager:v0.34.0 config routes test \
      --config.file="/work/$environment-alertmanager.yaml" "$@"
  }
  am_route --verify.receivers=discord "environment=$environment" notify=discord severity=critical
  other=prod
  if [[ "$environment" == prod ]]; then other=stage; fi
  am_route --verify.receivers=null "environment=$other" notify=discord severity=critical
  am_route --verify.receivers=null notify=discord severity=warning
  am_route --verify.receivers=null "environment=$environment" severity=warning
done
