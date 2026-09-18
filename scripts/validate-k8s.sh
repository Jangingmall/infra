#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash scripts/validate-k8s.sh [--help]

Render k8s/base, k8s/overlays/stage, and k8s/overlays/prod.
Render pending DB egress, Backend, and full AI policy bundles.
DB/AI ingress and the AI vector DB isolation policy are enabled in the overlays.
Render Argo CD Applications and lint/render platform and observability Helm charts.
Requires kubectl, Helm, Ruby, Docker, and internet access to the public chart repositories.
No cluster connection or AWS credentials are required.
EOF
}

if [[ $# -eq 1 && $1 == '--help' ]]; then
  usage
  exit 0
fi
if [[ $# -ne 0 ]]; then
  usage >&2
  exit 2
fi

for tool in kubectl helm ruby; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$tool" >&2
    exit 1
  fi
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validation_dir="$(mktemp -d "${TMPDIR:-/tmp}/jangin-k8s-validation.XXXXXX")"
trap 'rm -rf "$validation_dir"' EXIT
mkdir -p "$validation_dir/charts" "$validation_dir/helm-cache"

printf 'Tool versions\n'
kubectl version --client
helm version --short

for target in base overlays/stage overlays/prod; do
  printf '\nRendering k8s/%s\n' "$target"
  kubectl kustomize "$repo_root/k8s/$target" > "$validation_dir/${target##*/}.yaml"
done

for target in database/egress backend ai; do
  printf '\nRendering opt-in %s policies (not applied)\n' "$target"
  kubectl kustomize "$repo_root/k8s/base/network-policies/$target" \
    > "$validation_dir/policy-${target##*/}.yaml"
done

validate_chart() {
  local release="$1"
  local chart="$2"
  local version="$3"
  local namespace="$4"
  local repository="$5"
  local values="$repo_root/$6"
  local chart_dir="$validation_dir/charts/$chart"

  printf '\nValidating %s (chart %s)\n' "$release" "$version"
  helm pull "$chart" \
    --repo "$repository" \
    --version "$version" \
    --untar --untardir "$validation_dir/charts" \
    --repository-cache "$validation_dir/helm-cache" \
    --repository-config "$validation_dir/repositories.yaml"

  helm lint "$chart_dir" --strict --namespace "$namespace" --values "$values"
  helm template "$release" "$chart_dir" \
    --namespace "$namespace" --values "$values" --include-crds \
    > "$validation_dir/$release.yaml"
}

for environment in stage prod; do
  kubectl kustomize "$repo_root/argocd/applications/$environment" \
    > "$validation_dir/argocd-$environment.yaml"
done

validate_chart argocd argo-cd 10.9.1 argocd \
  https://argoproj.github.io/argo-helm \
  platform/argocd/values.yaml

validate_chart cloudnative-pg cloudnative-pg 0.29.0 cnpg-system \
  https://cloudnative-pg.github.io/charts \
  platform/cloudnative-pg/values.yaml

validate_chart argo-rollouts argo-rollouts 2.43.1 argo-rollouts \
  https://argoproj.github.io/argo-helm \
  platform/argo-rollouts/values.yaml

validate_chart secrets-store-csi secrets-store-csi-driver-provider-aws 3.1.3 kube-system \
  https://aws.github.io/secrets-store-csi-driver-provider-aws \
  platform/secrets-store-csi/values.yaml

kubectl kustomize "$repo_root/platform/observability/platform" > "$validation_dir/platform-monitoring.yaml"
ruby "$repo_root/scripts/validate-platform-monitoring.rb" "$validation_dir"
ruby "$repo_root/scripts/validate-gitops.rb" "$validation_dir"
bash "$repo_root/scripts/validate-observability-gitops.sh"

printf '\nKubernetes configuration validation passed.\n'
