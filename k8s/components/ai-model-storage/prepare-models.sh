#!/bin/sh
set -eu

if [ "${1:-}" = --help ]; then
  echo 'Required: MODEL_S3_URI, MODEL_BUNDLE_SHA256, MODEL_ROOT, MODEL_KIND (sglang|chatbot|chatbot-llm). Requires aws and sha256sum.'
  exit 0
fi
: "${MODEL_S3_URI:?S3 bundle prefix is required}"
: "${MODEL_BUNDLE_SHA256:?SHA256SUMS digest is required}"
: "${MODEL_ROOT:?Persistent model directory is required}"
: "${MODEL_KIND:?sglang, chatbot or chatbot-llm is required}"
case "$MODEL_S3_URI" in s3://?*/?*) ;; *) echo 'Expected s3://bucket/prefix' >&2; exit 1 ;; esac
case "$MODEL_BUNDLE_SHA256" in *[!a-f0-9]*|'') exit 1 ;; esac
[ "${#MODEL_BUNDLE_SHA256}" -eq 64 ]
case "$MODEL_KIND" in sglang|chatbot|chatbot-llm) ;; *) exit 1 ;; esac

mkdir -p "$MODEL_ROOT/$MODEL_BUNDLE_SHA256"
cd "$MODEL_ROOT/$MODEL_BUNDLE_SHA256"
verify_manifest() {
  printf '%s  SHA256SUMS\n' "$MODEL_BUNDLE_SHA256" | sha256sum -c - >/dev/null || return 1
  awk 'NF != 2 || length($1) != 64 || $1 ~ /[^a-f0-9]/ || $2 !~ /^[A-Za-z0-9_][A-Za-z0-9_.\/-]*$/ || $2 ~ /(^|\/)\.\.?($|\/)/ || $2 == "SHA256SUMS" { bad=1 } END { exit (bad || NR==0) }' SHA256SUMS || return 1
  case "$MODEL_KIND" in
    sglang) required='text/config.json image/model_index.json u2net/birefnet-general.onnx' ;;
    chatbot) required='bge-m3/config.json bge-m3/modules.json bge-m3/1_Pooling/config.json bge-m3/tokenizer.json' ;;
    chatbot-llm) required='llm/config.json llm/tokenizer.json llm/tokenizer_config.json' ;;
  esac
  for path in $required; do
    awk -v path="$path" '$2 == path { found=1 } END { exit !found }' SHA256SUMS || return 1
  done
  if [ "$MODEL_KIND" = chatbot ]; then
    awk '$2 == "bge-m3/model.safetensors" || $2 == "bge-m3/pytorch_model.bin" { found=1 } END { exit !found }' SHA256SUMS || return 1
  fi
  if [ "$MODEL_KIND" = chatbot-llm ]; then
    awk '$2 ~ /^llm\/[^\/]+\.safetensors$/ { found=1 } END { exit !found }' SHA256SUMS || return 1
  fi
}
if [ -f .complete ] && verify_manifest && sha256sum -c SHA256SUMS >/dev/null; then
  echo 'Verified cached model bundle'
  exit 0
fi
rm -f .complete
aws s3 cp "${MODEL_S3_URI%/}/SHA256SUMS" SHA256SUMS --only-show-errors
verify_manifest || { echo 'Invalid or incompatible model manifest' >&2; exit 1; }
# 검증한 목록의 파일만 가져온다. 중단되면 완료 표시가 없어 다음 시작 때 다시 준비한다.
while read -r checksum path; do
  mkdir -p "$(dirname "$path")"
  aws s3 cp "${MODEL_S3_URI%/}/$path" "$path" --only-show-errors
done < SHA256SUMS
sha256sum -c SHA256SUMS >/dev/null
touch .complete
echo 'Model bundle ready'
