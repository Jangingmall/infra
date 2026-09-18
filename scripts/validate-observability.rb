#!/usr/bin/env ruby
require 'yaml'
require 'json'

def check(condition, message)
  abort "Observability validation failed: #{message}" unless condition
end

environment, rendered = ARGV
check(%w[stage prod].include?(environment) && rendered, 'expected stage|prod and rendered YAML')
resources = YAML.load_stream(File.read(rendered)).compact
find = ->(kind) { resources.find { |r| r['kind'] == kind } }
prometheus = find.call('Prometheus')&.fetch('spec')
check(prometheus, 'Prometheus missing')
check(prometheus.dig('nodeSelector', 'node.kubernetes.io/instance-type') == 't3.large', 'Prometheus must use the large System node')
check(prometheus['retention'] == (environment == 'stage' ? '7d' : '15d'), 'retention differs')
check(prometheus['retentionSize'] == (environment == 'stage' ? '16GB' : '32GB'), 'size guard differs')
check(prometheus['scrapeInterval'] == '30s', 'scrape interval differs')
check(prometheus.dig('externalLabels', 'environment') == environment, 'environment label differs')
check(prometheus.dig('storage', 'volumeClaimTemplate', 'spec', 'storageClassName') == 'gp3-monitoring', 'Prometheus PVC missing')
%w[serviceMonitor podMonitor rule].each do |type|
  check(prometheus.dig("#{type}Selector", 'matchLabels', 'release') == 'metrics', "#{type} release selector differs")
  check(prometheus.dig("#{type}NamespaceSelector", 'matchLabels', 'kubernetes.io/metadata.name') == 'monitoring', "#{type} namespace selector differs")
end
%w[Prometheus Alertmanager].each do |kind|
  spec = find.call(kind).fetch('spec')
  check(spec.dig('nodeSelector', 'workload-type') == 'system', "#{kind} placement differs")
  check(spec.dig('resources', 'requests', 'memory'), "#{kind} memory request missing")
end
resources.select { |r| %w[Deployment Job].include?(r['kind']) }.each do |r|
  spec = r.dig('spec', 'template', 'spec')
  check(spec.dig('nodeSelector', 'workload-type') == 'system', "#{r.dig('metadata', 'name')} must use System nodes")
  spec.fetch('containers').each do |c|
    check(c.dig('resources', 'requests', 'cpu') && c.dig('resources', 'requests', 'memory'), "#{c['name']} requests missing")
  end
end
exporter = find.call('DaemonSet')&.dig('spec', 'template', 'spec')
check(exporter && exporter.dig('nodeSelector', 'kubernetes.io/os') == 'linux', 'node-exporter Linux selector missing')
check(exporter['tolerations'].any? { |t| t['operator'] == 'Exists' && t['effect'] == 'NoSchedule' }, 'node-exporter must tolerate DB/GPU taints')
check(resources.none? { |r| r['kind'] == 'Ingress' }, 'public ingress is forbidden')
resources.select { |r| r['kind'] == 'Service' }.each do |s|
  check([nil, 'ClusterIP'].include?(s.dig('spec', 'type')), 'non-internal service found')
end
monitors = resources.select { |r| r['kind'] == 'ServiceMonitor' }
check(monitors.any? { |r| r.dig('metadata', 'name').include?('kubelet') }, 'kubelet monitor missing')
monitors.each do |m|
  check(m.dig('metadata', 'labels', 'release') == 'metrics', 'monitor is not selected by Prometheus')
  check(m.dig('metadata', 'namespace') == 'monitoring', 'monitor namespace differs')
  check(m.dig('metadata', 'name') !~ /etcd|kube-controller-manager|kube-scheduler|kube-proxy/, 'unreachable EKS target enabled')
end
grafana = resources.find { |r| r['kind'] == 'Deployment' && r.dig('metadata', 'name') == 'metrics-grafana' }
container = grafana.dig('spec', 'template', 'spec', 'containers').find { |c| c['name'] == 'grafana' }
check(grafana.dig('spec', 'template', 'spec', 'containers').map { |c| c['name'] } == ['grafana'], 'Grafana sidecars must stay disabled')
volumes = grafana.dig('spec', 'template', 'spec', 'volumes')
dashboards = resources.select { |r| r['kind'] == 'ConfigMap' && r.fetch('data', {}).keys.any? { |k| k.end_with?('.json') } }
check(!dashboards.empty?, 'default dashboards disappeared')
{
  'backend'=>'backend/dashboard.json', 'gpu'=>'gpu/dashboard.json',
  'cnpg'=>'platform/cnpg-dashboard.json', 'argo'=>'platform/argo-dashboard.json'
}.each do |name, path|
  cm = dashboards.find { |r| r.dig('metadata','name')=="metrics-dashboard-#{name}" }
  expected = File.read(File.expand_path("../platform/observability/#{path}", __dir__))
  check(cm && JSON.parse(cm.fetch('data').fetch("#{name}.json"))==JSON.parse(expected), "#{name} dashboard differs from Git source")
end

dashboards.each do |cm|
  volume = volumes.find { |v| v.dig('configMap', 'name') == cm.dig('metadata', 'name') }
  check(volume, "dashboard ConfigMap not mounted: #{cm.dig('metadata', 'name')}")
  mount = container['volumeMounts'].find { |v| v['name'] == volume['name'] }
  # ConfigMap volumes are read-only even when the chart omits volumeMount.readOnly.
  check(mount && volume['configMap'] && mount['readOnly'] != false, 'dashboard must use a read-only ConfigMap')
  if mount['subPath']
    check(grafana.dig('spec','template','metadata','annotations','checksum/dashboards-json-config'), 'subPath dashboard requires restart checksum')
  end
end
config = resources.find { |r| r['kind'] == 'ConfigMap' && r.dig('metadata', 'name') == 'metrics-grafana' }
ds = YAML.load(config.dig('data', 'datasources.yaml'))
check(ds['datasources'].map { |d| d['uid'] }.sort == %w[alertmanager loki prometheus tempo], 'file datasources missing')
tempo_ds = ds['datasources'].find { |d| d['uid'] == 'tempo' }
check(tempo_ds['type'] == 'tempo' && tempo_ds['access'] == 'proxy' && tempo_ds['url'] == 'http://tempo.monitoring.svc.cluster.local:3200' && tempo_ds['editable'] == false, 'Tempo datasource must use internal query service')
provider = YAML.load(config.dig('data', 'dashboardproviders.yaml'))['providers'].first
check(provider['allowUiUpdates'] == false && provider['updateIntervalSeconds'] == 30, 'dashboard file update contract differs')
check(grafana.dig('spec', 'template', 'metadata', 'annotations', 'checksum/config'), 'Grafana config restart checksum missing')
%w[GF_SECURITY_ADMIN_USER GF_SECURITY_ADMIN_PASSWORD].each do |name|
  env = container['env'].find { |e| e['name'] == name }
  check(env&.dig('valueFrom', 'secretKeyRef', 'name') == 'grafana-admin', 'Grafana must use supplied credentials')
end
check(resources.none? { |r| r['kind'] == 'Secret' && r.dig('metadata', 'name') == 'metrics-grafana' }, 'generated Grafana credentials found')
sc = YAML.load_file(File.expand_path('../platform/observability/metrics/storage-class.yaml', __dir__))
check(sc['provisioner'] == 'ebs.csi.aws.com' && sc.dig('parameters', 'encrypted') == 'true', 'encrypted EBS storage required')
check(sc['reclaimPolicy'] == 'Retain' && sc['volumeBindingMode'] == 'WaitForFirstConsumer', 'storage lifecycle differs')


backend = resources.find { |r| r['kind']=='PodMonitor' && r.dig('metadata','name')=='backend' }
check(backend && backend.dig('metadata','labels','release')=='metrics', 'Backend PodMonitor not selected')
check(backend.dig('spec','selector','matchLabels','app.kubernetes.io/name')=='backend', 'Backend selector differs')
endpoint = backend.dig('spec','podMetricsEndpoints')&.first
check(endpoint && endpoint['port']=='management' && endpoint['path']=='/actuator/prometheus' && endpoint['interval']=='30s', 'Backend scrape contract differs')
puts "#{environment}: metrics retention, storage, placement, selectors and internal services PASS"
