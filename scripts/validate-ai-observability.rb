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
JSON.parse(File.read(File.expand_path('../platform/observability/gpu/dashboard.json', __dir__)))
puts 'GPU scheduling, monitors and AI opt-in contract PASS'
