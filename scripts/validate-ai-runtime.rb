#!/usr/bin/env ruby
require 'yaml'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'digest'

if ARGV == ['--help']
  puts 'Usage: ruby scripts/validate-ai-runtime.rb [--help]'
  puts 'Render model storage in Stage/Prod fixtures; exercise download/cache/failure and registry-copy contracts without AWS.'
  exit
end
abort 'Unexpected arguments' unless ARGV.empty?
Dir.chdir(File.expand_path('..', __dir__))
repo = Dir.pwd
component = 'k8s/components/ai-model-storage'
def check(value, message)
  abort "AI runtime validation failed: #{message}" unless value
end
def run(*args)
  out, err, status = Open3.capture3(*args)
  check(status.success?, "#{args.last}: #{out}#{err}")
  out
end
Dir.mktmpdir('ai-runtime-') do |tmp|
  FileUtils.cp_r('k8s', tmp)
  %w[stage prod].each do |environment|
    original = YAML.load_stream(run('kubectl', 'kustomize', "k8s/overlays/#{environment}")).compact
    chatbot = original.find { |r| r['kind']=='Deployment' && r.dig('metadata','name')=='ai-ollama' }.dig('spec','template','spec','containers',0)
    check(chatbot.dig('readinessProbe','httpGet','path')=='/ai/ready', 'chatbot must gate DB/embedding/LLM readiness')
    check(!chatbot.dig('resources','limits','nvidia.com/gpu'), 'CPU chatbot image must not reserve a GPU')
    check(original.none? { |r| r.dig('metadata','name')=='ai-sglang-data' }, 'unconfigured model storage must remain opt-in')
    overlay = "#{tmp}/k8s/overlays/#{environment}"
    path = "#{overlay}/kustomization.yaml"
    config = YAML.load_file(path)
    config['components'] << '../../components/ai-model-storage'
    config['configMapGenerator'] = %w[sglang chatbot].map do |service|
      {'name'=>"ai-#{service}-model-source", 'namespace'=>'ai', 'literals'=>['s3-uri=s3://test-models/bundle', "manifest-sha256=#{'a'*64}"]}
    end
    config['images'] = [{'name'=>'ai-model-fetch', 'newName'=>'123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/jangin-ai/model-fetch', 'digest'=>"sha256:#{'b'*64}"}]
    File.write(path, config.to_yaml)
    docs = YAML.load_stream(run('kubectl', 'kustomize', overlay)).compact
    check(docs.count { |r| r['kind']=='PersistentVolumeClaim' && %w[ai-sglang-data ai-chatbot-models].include?(r.dig('metadata','name')) }==2, 'model claims missing')
    %w[ai-sglang ai-ollama].each do |name|
      pod = docs.find { |r| r['kind']=='Deployment' && r.dig('metadata','name')==name }.dig('spec','template','spec')
      init = pod['initContainers'].find { |c| c['name']=='model-preparation' }
      check(init['image'].end_with?("@sha256:#{'b'*64}"), 'fetch image digest must replace alias')
      check(init.dig('securityContext','runAsUser')==10001 && pod.dig('securityContext','fsGroup')==10001, 'PVC ownership mismatch')
      check(pod['volumes'].any? { |v| v.dig('configMap','name')&.start_with?('ai-model-preparation-') }, 'hashed preparation ConfigMap not connected')
      container = pod['containers'].first
      names = container['env'].map { |e| e['name'] }
      model_env = name=='ai-sglang' ? 'TEXT_MODEL_PATH' : 'EMBED_MODEL'
      check(names.index('MODEL_BUNDLE_SHA256') < names.index(model_env), 'Kubernetes dependent environment expansion order is invalid')
      check(pod['volumes'].any? { |v| v['csi'] }, 'existing CSI secrets lost')
    end
    puts "#{environment}: default gate and enabled model-storage rendering PASS"
  end

  bin = "#{tmp}/bin"; FileUtils.mkdir_p(bin)
  File.write("#{bin}/aws", <<~SH)
    #!/bin/sh
    set -eu
    echo "$*" >> "$TEST_CALLS"
    [ "$1 $2" = 's3 cp' ]
    source="${3#s3://test-models/bundle/}"
    cp "$TEST_BUNDLE/$source" "$4"
  SH
  FileUtils.chmod(0755, "#{bin}/aws")
  bundle = "#{tmp}/bundle"; FileUtils.mkdir_p(bundle)
  files = %w[bge-m3/config.json bge-m3/modules.json bge-m3/1_Pooling/config.json bge-m3/tokenizer.json bge-m3/model.safetensors]
  files.each { |f| FileUtils.mkdir_p(File.dirname("#{bundle}/#{f}")); File.write("#{bundle}/#{f}", 'fixture') }
  manifest = files.map { |f| "#{Digest::SHA256.file("#{bundle}/#{f}").hexdigest}  #{f}\n" }.join
  File.write("#{bundle}/SHA256SUMS", manifest)
  hash = Digest::SHA256.hexdigest(manifest)
  env = {'PATH'=>"#{bin}:#{ENV.fetch('PATH')}", 'MODEL_S3_URI'=>'s3://test-models/bundle', 'MODEL_BUNDLE_SHA256'=>hash, 'MODEL_ROOT'=>"#{tmp}/models", 'MODEL_KIND'=>'chatbot', 'TEST_BUNDLE'=>bundle, 'TEST_CALLS'=>"#{tmp}/calls"}
  script = "#{repo}/#{component}/prepare-models.sh"
  run('sh', script, '--help')
  run(env, 'sh', script)
  calls = File.read(env['TEST_CALLS'])
  run(env, 'sh', script)
  check(File.read(env['TEST_CALLS'])==calls, 'verified cache must not download again')
  File.write("#{tmp}/models/#{hash}/bge-m3/config.json", 'corrupt')
  run(env, 'sh', script)
  check(File.read("#{tmp}/models/#{hash}/bge-m3/config.json")=='fixture', 'corrupt cache must be repaired')
  FileUtils.rm("#{bundle}/bge-m3/model.safetensors")
  FileUtils.rm("#{tmp}/models/#{hash}/.complete")
  _, _, status = Open3.capture3(env, 'sh', script)
  check(!status.success? && !File.exist?("#{tmp}/models/#{hash}/.complete"), 'failed download must not become ready')
  _, _, status = Open3.capture3(env.merge('MODEL_BUNDLE_SHA256'=>'0'*64), 'sh', script)
  check(!status.success?, 'changed manifest must be rejected')
  files = %w[text/config.json image/model_index.json u2net/birefnet-general.onnx]
  files.each { |f| FileUtils.mkdir_p(File.dirname("#{bundle}/#{f}")); File.write("#{bundle}/#{f}", 'fixture') }
  manifest = files.map { |f| "#{Digest::SHA256.file("#{bundle}/#{f}").hexdigest}  #{f}\n" }.join
  File.write("#{bundle}/SHA256SUMS", manifest)
  run(env.merge('MODEL_KIND'=>'sglang', 'MODEL_BUNDLE_SHA256'=>Digest::SHA256.hexdigest(manifest)), 'sh', script)
  puts 'Model preparation: both layouts, first download, verified cache, corruption repair, missing file and bad manifest PASS'
end
run('bash', 'scripts/mirror-ai-image.sh', '--help')
%w[model-fetch sglang ollama].each do |runtime|
  run({'RUNTIME'=>runtime, 'SOURCE_DIGEST'=>"sha256:#{'a'*64}"}, 'bash', 'scripts/mirror-ai-image.sh', '--validate')
end
_, _, status = Open3.capture3({'RUNTIME'=>'sglang', 'SOURCE_DIGEST'=>'latest'}, 'bash', 'scripts/mirror-ai-image.sh', '--validate')
check(!status.success?, 'mirror must reject mutable tags before AWS login')
puts 'Image mirror source/digest validation PASS (no registry copy performed)'
Dir.mktmpdir('ai-image-copy-') do |tmp|
  File.write("#{tmp}/aws", <<~SH)
    #!/bin/sh
    set -eu
    case "$1 $2" in
      'ecr describe-repositories') echo '123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/jangin-ai/chatbot-llm' ;;
      'ecr describe-images')
        if [ "${TEST_DENIED:-}" = 1 ]; then echo 'AccessDeniedException' >&2; exit 254; fi
        if [ -f "$TEST_STATE" ]; then cat "$TEST_STATE"; else echo 'ImageNotFoundException' >&2; exit 254; fi ;;
      'ecr get-login-password') echo 'test-only-password' ;;
      *) exit 2 ;;
    esac
  SH
  File.write("#{tmp}/skopeo", <<~SH)
    #!/bin/sh
    set -eu
    echo "$*" >> "$TEST_CALLS"
    case "$1" in
      login) cat >/dev/null ;;
      copy) printf '%s\n' "$SOURCE_DIGEST" > "$TEST_STATE" ;;
      *) exit 2 ;;
    esac
  SH
  FileUtils.chmod(0755, ["#{tmp}/aws", "#{tmp}/skopeo"])
  env = {'PATH'=>"#{tmp}:#{ENV.fetch('PATH')}", 'RUNTIME'=>'sglang', 'SOURCE_DIGEST'=>"sha256:#{'a'*64}", 'AWS_REGION'=>'ap-northeast-2', 'TEST_STATE'=>"#{tmp}/state", 'TEST_CALLS'=>"#{tmp}/calls", 'GITHUB_STEP_SUMMARY'=>"#{tmp}/summary"}
  run(env, 'bash', 'scripts/mirror-ai-image.sh')
  calls = File.read(env['TEST_CALLS'])
  check(calls.include?('copy --all --preserve-digests'), 'mirror must retain upstream digest/index')
  check(File.read(env['GITHUB_STEP_SUMMARY']).include?("@#{env['SOURCE_DIGEST']}"), 'handoff summary needs verified digest')
  run(env, 'bash', 'scripts/mirror-ai-image.sh')
  check(File.read(env['TEST_CALLS'])==calls, 'same digest must not be copied twice')
  File.write(env['TEST_STATE'], "sha256:#{'b'*64}")
  _, _, status = Open3.capture3(env, 'bash', 'scripts/mirror-ai-image.sh')
  check(!status.success?, 'existing mismatched tag must fail')
  _, _, status = Open3.capture3(env.merge('TEST_DENIED'=>'1'), 'bash', 'scripts/mirror-ai-image.sh')
  check(!status.success? && File.read(env['TEST_CALLS'])==calls, 'AWS errors must not trigger a copy')
  puts 'Image mirror CLI: copy/summary, idempotence, mismatched tag and denied AWS access PASS (mock tools)'
end
