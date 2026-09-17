#!/usr/bin/env ruby
require 'yaml'
require 'json'
def check(condition, message)
  abort "AI observability validation failed: #{message}" unless condition
end
root = ARGV.fetch(0)
read = ->(name) { YAML.load_stream(File.read(File.join(root, "#{name}.yaml"))).compact }
gpu = read.call('gpu')
ds = gpu.find { |r| r['kind'] == 'DaemonSet' }.dig('spec', 'template', 'spec')
check(ds.dig('nodeSelector', 'workload-type') == 'gpu', 'GPU node selector missing')
check(ds['tolerations'].any? { |t| t == {'key'=>'nvidia.com/gpu','operator'=>'Equal','value'=>'true','effect'=>'NoSchedule'} }, 'GPU taint mismatch')
check(!ds['hostNetwork'] && !ds['hostPID'] && ds['automountServiceAccountToken'] == false, 'unnecessary host/API access')
check(ds['containers'].none? { |c| c.fetch('resources').values.any? { |v| v.key?('nvidia.com/gpu') } }, 'Exporter must not reserve AI GPU')
monitor = gpu.find { |r| r['kind'] == 'ServiceMonitor' }
check(monitor.dig('metadata','labels','release') == 'metrics', 'GPU monitor not selected')
check(monitor.dig('spec','endpoints',0,'interval') == '30s', 'GPU scrape interval mismatch')
check(gpu.none? { |r| %w[ClusterRole ClusterRoleBinding].include?(r['kind']) }, 'Exporter cluster RBAC unexpected')
policies = read.call('gpu-policies')
check(policies.first.dig('spec','egress') == [], 'DCGM external egress not required')
ai = read.call('ai-metrics').find { |r| r['kind'] == 'PodMonitor' }
check(ai.dig('spec','namespaceSelector','matchNames') == ['ai'], 'AI namespace mismatch')
check(ai.dig('spec','selector','matchExpressions',0,'values').sort == %w[ai-ollama ai-sglang], 'AI engine selector mismatch')
check(ai.dig('spec','podMetricsEndpoints',0,'port') == 'http' && ai.dig('spec','podMetricsEndpoints',0,'path') == '/metrics', 'AI API contract mismatch')
app_egress = read.call('trace-application-egress')
check(app_egress.map { |r| r.dig('metadata','namespace') }.sort == %w[ai app], 'application egress namespace overwritten')
%w[stage prod].each do |env|
  resources = read.call("traces-#{env}")
  dep = resources.find { |r| r['kind'] == 'Deployment' }
  check(dep.dig('spec','replicas') == 1, 'Collector must remain single replica pending capacity decision')
  spec = dep.dig('spec','template','spec')
  check(spec.dig('nodeSelector','workload-type') == 'system' && spec['automountServiceAccountToken'] == false, 'Collector placement/API access mismatch')
  config = resources.find { |r| r['kind']=='ConfigMap' && r.fetch('data',{}).key?('config.yaml') }
  check(spec['volumes'].any? { |v| v.dig('configMap','name') == config.dig('metadata','name') }, 'Collector config hash not wired')
  settings = YAML.load(config.dig('data','config.yaml'))
  check(settings.dig('service','pipelines','traces','processors') == %w[memory_limiter resource/environment batch], 'memory limiter must precede batching')
  check(settings.dig('receivers','otlp','protocols').keys == ['grpc'], 'only OTLP gRPC was chosen')
  check(settings.dig('exporters','otlp/tempo','sending_queue','queue_size') == 32, 'bounded queue changed')
  env_cm = resources.find { |r| r['kind']=='ConfigMap' && r.fetch('data',{}).key?('OBS_ENV') }
  check(env_cm.dig('data','OBS_ENV') == env, 'trace environment mismatch')
  check(resources.none? { |r| r.dig('metadata','name') == 'traces-runtime' }, 'do not fabricate Tempo endpoint')
  check(resources.none? { |r| %w[app ai].include?(r.dig('metadata','namespace')) }, 'Collector bundle must not newly isolate application egress')
  check(resources.none? { |r| r['kind']=='Ingress' }, 'no public trace ingress')
end
JSON.parse(File.read(File.expand_path('../platform/observability/gpu/dashboard.json', __dir__)))
puts 'GPU scheduling, monitors, AI opt-in contract and Stage/Prod trace configuration PASS'
