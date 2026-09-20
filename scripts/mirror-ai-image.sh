#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo 'Usage: RUNTIME=model-fetch|sglang|ollama SOURCE_DIGEST=sha256:<64 hex> bash scripts/mirror-ai-image.sh [--validate|--help]'
  echo 'Copies an existing image to a pre-created ECR repository. Requires aws, skopeo and OIDC credentials.'
}
if [[ ${1:-} == --help ]]; then usage; exit 0; fi
if [[ $# -gt 1 || ( $# -eq 1 && $1 != --validate ) ]]; then usage >&2; exit 2; fi
case "${RUNTIME:-}" in
  model-fetch) source=public.ecr.aws/aws-cli/aws-cli; repository=jangin-ai/model-fetch ;;
  sglang) source=docker.io/lmsysorg/sglang; repository=jangin-ai/chatbot-llm ;;
  ollama) source=docker.io/ollama/ollama; repository=jangin-ai/chatbot-llm ;;
  *) echo 'Unknown runtime' >&2; exit 2 ;;
esac
if [[ ! ${SOURCE_DIGEST:-} =~ ^sha256:[a-f0-9]{64}$ ]]; then
  echo 'SOURCE_DIGEST must be a pinned sha256 digest, not a tag' >&2
  exit 2
fi
if [[ ${1:-} == --validate ]]; then
  printf '%s@%s -> %s\n' "$source" "$SOURCE_DIGEST" "$repository"
  exit 0
fi
: "${AWS_REGION:?AWS_REGION is required}"
uri="$(aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$repository" --query 'repositories[0].repositoryUri' --output text)"
[[ "$uri" == *.dkr.ecr.*.amazonaws.com/"$repository" ]] || { echo 'Unexpected ECR URI' >&2; exit 1; }
tag="sha256-${SOURCE_DIGEST#sha256:}"
registry="${uri%%/*}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if existing="$(aws ecr describe-images --region "$AWS_REGION" --repository-name "$repository" --image-ids "imageTag=$tag" --query 'imageDetails[0].imageDigest' --output text 2>"$tmp/error")"; then
  [[ "$existing" == "$SOURCE_DIGEST" ]] || { echo 'Existing tag has a different digest' >&2; exit 1; }
else
  if ! grep -q 'ImageNotFoundException' "$tmp/error"; then cat "$tmp/error" >&2; exit 1; fi
  aws ecr get-login-password --region "$AWS_REGION" |
    skopeo login --authfile "$tmp/auth.json" --username AWS --password-stdin "$registry"
  skopeo copy --all --preserve-digests --authfile "$tmp/auth.json" \
    "docker://$source@$SOURCE_DIGEST" "docker://$uri:$tag"
fi
actual="$(aws ecr describe-images --region "$AWS_REGION" --repository-name "$repository" --image-ids "imageTag=$tag" --query 'imageDetails[0].imageDigest' --output text)"
[[ "$actual" == "$SOURCE_DIGEST" ]] || { echo 'ECR digest verification failed' >&2; exit 1; }
printf 'Verified image: %s@%s\n' "$uri" "$actual"
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  {
    printf '### %s\n\n' "$RUNTIME"
    printf 'Upstream: `%s@%s`\n\n' "$source" "$SOURCE_DIGEST"
    printf 'ECR image: `%s@%s`\n\n' "$uri" "$actual"
    printf '모델 가중치는 포함하지 않습니다. 배포 설정은 별도 PR에서 이 digest로 변경합니다.\n'
  } >> "$GITHUB_STEP_SUMMARY"
fi
