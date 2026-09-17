#!/usr/bin/env ruby
# 고정 chart의 실제 Service → Pod → containerPort 경로와 관측성 selector를 대조한다.
require 'yaml'
require 'json'

def check(condition, message)
  abort "Platform monitoring validation failed: #{message}" unless condition
end

def matches?(selector, labels)
  selector.all? { |key, value| labels[key] == value }
end

def documents(path)
  YAML.load_stream(File.read(path)).compact
end

render_dir = ARGV.fetch(0)
root = File.expand_path('..', __dir__)
bundle = documents(File.join(render_dir, 'platform-monitoring.yaml'))
charts = %w[argocd argo-rollouts cloudnative-pg].flat_map { |name| documents("#{render_dir}/#{name}.yaml") }
workloads = charts.select { |r| %w[Deployment StatefulSet].include?(r['kind']) }
monitors = bundle.select { |r| %w[PodMonitor ServiceMonitor].include?(r['kind']) }
check(monitors.length == 7, 'expected CNPG DB/Operator plus five Argo monitors')
expected = {'cnpg-database'=>9187, 'cnpg-operator'=>8080, 'argocd-controller'=>8082,
            'argocd-server'=>8083, 'argocd-repo-server'=>8084, 'argocd-applicationset'=>8080, 'argo-rollouts'=>8090}
monitors.each do |monitor|
  name = monitor.dig('metadata','name')
  check(monitor.dig('metadata','namespace') == 'monitoring' && monitor.dig('metadata','labels','release') == 'metrics', "#{name}: Prometheus selector mismatch")
  spec = monitor.fetch('spec')
  ns = spec.dig('namespaceSelector','matchNames').fetch(0)
  selector = spec.dig('selector','matchLabels')
  ep = (spec['endpoints'] || spec['podMetricsEndpoints']).fetch(0)
  check(ep['interval']=='30s' && ep['scrapeTimeout']=='10s' && ep['path']=='/metrics', "#{name}: scrape contract mismatch")
  check(ep['honorLabels']==false, "#{name}: unexpected metric label authority")
  if name == 'cnpg-database'
    %w[stage prod].each do |env|
      cluster = documents("#{render_dir}/#{env}.yaml").find { |r| r['kind']=='Cluster' }
      check(ns==cluster.dig('metadata','namespace') && selector=={'cnpg.io/cluster'=>cluster.dig('metadata','name')}, 'CNPG Cluster selector mismatch')
      check(ep['port']=='metrics', 'CNPG 1.30 documented metrics port name mismatch')
    end
  else
    target_selector = selector
    target_port = ep['port']
    if monitor['kind']=='ServiceMonitor'
      services = charts.select { |r| r['kind']=='Service' && r.dig('metadata','namespace')==ns && matches?(selector,r.dig('metadata','labels')) }
      check(services.length==1, "#{name}: must select exactly one metrics Service")
      service = services.fetch(0)
      check([nil,'ClusterIP'].include?(service.dig('spec','type')), "#{name}: metrics exposed externally")
      ports = service.dig('spec','ports').select { |p| p['name']==ep['port'] }
      check(ports.length==1, "#{name}: Service port name mismatch")
      target_port = ports.fetch(0)['targetPort']
      target_selector = service.dig('spec','selector')
      check(ep.fetch('metricRelabelings').last == {'sourceLabels'=>['exported_namespace'],'regex'=>'(.+)','targetLabel'=>'resource_namespace'}, "#{name}: observed resource namespace lost")
    end
    pods = workloads.select { |r| r.dig('metadata','namespace')==ns && matches?(target_selector,r.dig('spec','template','metadata','labels')) }
    check(pods.length==1, "#{name}: target Pod selector mismatch")
    ports = pods.fetch(0).dig('spec','template','spec','containers').flat_map { |c| c.fetch('ports',[]) }
    check(ports.any? { |p| p['name']==target_port && p['containerPort']==expected.fetch(name) }, "#{name}: container metrics port mismatch")
    # 정책이 Service label이 아니라 실제 Pod label을 선택하는지 확인한다.
    np = bundle.find { |r| r['kind']=='NetworkPolicy' && r.dig('metadata','name')=="monitor-#{name}" }
    check(np.dig('metadata','namespace')==ns && matches?(np.dig('spec','podSelector','matchLabels'),pods.fetch(0).dig('spec','template','metadata','labels')), "#{name}: NetworkPolicy does not select target Pod")
  end
  policy = bundle.find { |r| r['kind']=='NetworkPolicy' && r.dig('metadata','name')=="monitor-#{name}" }
  check(policy.dig('spec','policyTypes')==['Ingress'], "#{name}: do not introduce egress isolation")
  ingress = policy.dig('spec','ingress')
  metric_rules = ingress.select { |rule| rule.fetch('ports').any? { |p| p['port']==expected.fetch(name) } }
  check(metric_rules.length==1, "#{name}: ambiguous metrics policy")
  peer = metric_rules.first.fetch('from').fetch(0)
  check(peer.dig('namespaceSelector','matchLabels','kubernetes.io/metadata.name')=='monitoring' && peer.dig('podSelector','matchLabels','operator.prometheus.io/name')=='metrics-prometheus', "#{name}: metrics peer is not Prometheus")
end
# 새 ingress 제한이 기존 webhook/API 통신을 막지 않는지 확인한다.
{'cnpg-operator'=>[9443],'argocd-server'=>[8080],'argocd-repo-server'=>[8081],'argocd-applicationset'=>[7000,8081],'argo-rollouts'=>[8080]}.each do |name,ports|
  policy = bundle.find { |r| r['kind']=='NetworkPolicy' && r.dig('metadata','name')=="monitor-#{name}" }
  allowed = policy.dig('spec','ingress').select { |r| !r.key?('from') }.flat_map { |r| r['ports'].map { |p| p['port'] } }
  check(allowed.sort==ports.sort, "#{name}: existing control port access changed")
end
check(charts.none? { |r| %w[PodMonitor ServiceMonitor].include?(r['kind']) }, 'chart Monitor would duplicate separately managed targets')
Dir["#{root}/platform/observability/platform/*-dashboard.json"].each do |path|
  dashboard = JSON.parse(File.read(path))
  dashboard['panels'].reject { |p| p['type']=='text' }.each do |p|
    check(p.dig('datasource','uid')=='prometheus', 'dashboard datasource mismatch')
    p.fetch('targets').each do |target|
      expr = target.fetch('expr')
      check(!expr.include?('rollout_phase') && !expr.include?('last_available_backup_timestamp'), 'deprecated metric used')
    end
  end
end
puts 'CNPG/Argo: seven monitors match chart Pod/Service ports, namespace mapping and ingress contracts PASS'
