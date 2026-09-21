#!/usr/bin/env ruby
require 'yaml'

def check(condition, message)
  abort "Cluster addons validation failed: #{message}" unless condition
end

def documents(path)
  YAML.load_stream(File.read(path)).compact
end

def runtime_ready(environment, required: false)
  root = File.expand_path('..', __dir__)
  values = YAML.load_file("#{root}/platform/aws-load-balancer-controller/runtime/#{environment}.yaml")
  arn = values.dig('serviceAccount', 'annotations', 'eks.amazonaws.com/role-arn').to_s
  ready = values['vpcId'].to_s.match?(/\Avpc-[0-9a-f]{8}(?:[0-9a-f]{9})?\z/) &&
          arn.match?(/\Aarn:aws:iam::[0-9]{12}:role\/.+\z/) &&
          !values['clusterName'].to_s.empty? && !values['region'].to_s.empty?
  check(ready, "#{environment}: actual VPC ID, IRSA ARN, clusterName and region are required before Sync") if required
  warn "#{environment}: ALB runtime values pending; do not Sync the Controller" unless ready
end

if ARGV == ['--help']
  puts 'Usage: ruby scripts/validate-cluster-addons.rb RENDER_DIR | --ready stage|prod'
  exit
end
if ARGV.first == '--ready'
  check(ARGV.size == 2 && %w[stage prod].include?(ARGV[1]), 'expected --ready stage|prod')
  runtime_ready(ARGV[1], required: true)
  puts "#{ARGV[1]}: runtime values present (AWS existence/trust still requires live verification)"
  exit
end
check(ARGV.size == 1 && File.directory?(ARGV[0]), 'expected render directory; use --help')
render_dir = ARGV[0]

%w[stage prod].each do |environment|
  runtime_ready(environment)
  argo = documents("#{render_dir}/argocd-#{environment}.yaml")
  project = argo.find { |r| r['kind'] == 'AppProject' && r.dig('metadata', 'name') == "#{environment}-platform" }
  check(project, "#{environment}: platform project missing")
  %w[aws-load-balancer-controller metrics-server].each do |name|
    app = argo.find { |r| r['kind'] == 'Application' && r.dig('metadata', 'name') == "#{environment}-#{name}" }
    check(app, "#{environment}: #{name} Application missing")
    spec = app.fetch('spec')
    source = spec.fetch('sources').find { |s| s['chart'] == name }
    version = name == 'metrics-server' ? '3.14.0' : '1.14.0'
    check(source && source['targetRevision'] == version && source.dig('helm', 'releaseName') == name, "#{name}: chart/release contract changed")
    check(spec.dig('syncPolicy', 'automated', 'enabled') == false && spec.dig('syncPolicy', 'automated', 'prune') == false, "#{name}: must start with manual Sync and no auto-prune")
    check(spec.dig('destination', 'namespace') == 'kube-system', "#{name}: wrong namespace")
    check(spec.dig('syncPolicy', 'syncOptions').include?('RespectIgnoreDifferences=true'), "#{name}: CA ownership not respected")
    check(spec.fetch('ignoreDifferences').any? { |d| (d['jsonPointers'] || d['jqPathExpressions']).any? { |p| p.include?('caBundle') } }, "#{name}: cert-manager CA injection must not be reconciled away")
    if name == 'aws-load-balancer-controller'
      check(source.dig('helm', 'valueFiles').include?("$values/platform/#{name}/runtime/#{environment}.yaml"), "#{environment}: wrong runtime values path")
    end
    file = name == 'metrics-server' ? name : "#{name}-#{environment}"
    rendered = documents("#{render_dir}/#{file}.yaml")
    deployment = rendered.find { |r| r['kind'] == 'Deployment' }
    check(deployment, "#{name}: Deployment missing")
    pod = deployment.dig('spec', 'template', 'spec')
    check(pod.dig('nodeSelector', 'workload-type') == 'system', "#{name}: System placement missing")
    check(pod['serviceAccountName'] == name, "#{name}: ServiceAccount mismatch")
    check(deployment.dig('spec', 'replicas') == (name == 'metrics-server' ? 1 : 2), "#{name}: replica budget changed")
    container = pod.fetch('containers').first
    check(container.dig('resources', 'requests', 'cpu') == '100m', "#{name}: CPU budget changed")
    check(container.dig('resources', 'requests', 'memory') == (name == 'metrics-server' ? '200Mi' : '128Mi'), "#{name}: memory budget changed")
    check(rendered.any? { |r| r['kind'] == 'Certificate' }, "#{name}: cert-manager serving certificate missing")
    check(rendered.none? { |r| r['kind'] == 'Secret' }, "#{name}: chart must not generate random TLS Secrets")
    args = container.fetch('args')
    if name == 'metrics-server'
      api = rendered.find { |r| r['kind'] == 'APIService' }
      check(api && api.dig('metadata', 'name') == 'v1beta1.metrics.k8s.io', 'Metrics API missing')
      check(api.dig('spec', 'insecureSkipTLSVerify') != true, 'Metrics API must verify serving TLS')
      check(api.dig('metadata', 'annotations', 'cert-manager.io/inject-ca-from') == 'kube-system/metrics-server', 'Metrics CA injection missing')
      check(args.none? { |a| a.start_with?('--kubelet-insecure-tls') }, 'kubelet TLS verification must stay enabled')
    else
      %w[--enable-shield=false --enable-waf=false --enable-wafv2=false --enable-backend-security-group=false].each do |arg|
        check(args.include?(arg), "ALB: #{arg} missing")
      end
      check(pod.fetch('containers').first.fetch('env').include?({'name'=>'AWS_EC2_METADATA_DISABLED', 'value'=>'true'}), 'ALB must not fall back to node IMDS credentials')
      check(rendered.any? { |r| r['kind'] == 'CustomResourceDefinition' && r.dig('metadata', 'name') == 'targetgroupbindings.elbv2.k8s.aws' }, 'TargetGroupBinding CRD missing')
      webhooks = rendered.select { |r| r['kind'] == 'MutatingWebhookConfiguration' }.flat_map { |r| r.fetch('webhooks') }
      check(webhooks.none? { |w| w.fetch('rules').any? { |r| r.fetch('resources').include?('services') } }, 'ALB must not mutate LoadBalancer Services by default')
    end
    cluster_kinds = %w[CustomResourceDefinition ClusterRole ClusterRoleBinding APIService MutatingWebhookConfiguration ValidatingWebhookConfiguration IngressClass]
    rendered.each do |r|
      group = r['apiVersion'].include?('/') ? r['apiVersion'].split('/').first : ''
      scope = cluster_kinds.include?(r['kind']) ? 'clusterResourceWhitelist' : 'namespaceResourceWhitelist'
      allowed = project.dig('spec', scope).any? { |rule| [group, '*'].include?(rule['group']) && [r['kind'], '*'].include?(rule['kind']) }
      check(allowed, "#{environment}: AppProject rejects #{r['kind']}")
    end
  end
  app = argo.find { |r| r['kind'] == 'Application' && r.dig('metadata', 'name') == "#{environment}-nvidia-device-plugin" }
  check(app, 'NVIDIA Application missing')
  source = app.fetch('spec').fetch('sources').find { |s| s['chart'] == 'nvidia-device-plugin' }
  check(source && source['targetRevision'] == '0.20.0' && source.dig('helm', 'valueFiles') == ['$values/platform/nvidia-device-plugin/values.yaml'], 'NVIDIA chart/values contract changed')
  check(app.dig('spec', 'syncPolicy', 'automated', 'enabled') == false, 'NVIDIA must start with manual Sync')
  resources = documents("#{render_dir}/nvidia-device-plugin.yaml")
  check(resources.count { |r| r['kind'] == 'DaemonSet' } == 2 && resources.all? { |r| %w[DaemonSet ServiceAccount ClusterRole ClusterRoleBinding].include?(r['kind']) }, 'NVIDIA chart must contain plugin/MPS DaemonSets and their RBAC only')
  mps = resources.find { |r| r.dig('metadata', 'name') == 'nvidia-device-plugin-mps-control-daemon' }
  check(mps && mps.dig('spec', 'template', 'spec', 'nodeSelector', 'nvidia.com/mps.capable') == 'true', 'MPS must require an explicit activation label')
  ds = resources.find { |r| r.dig('metadata', 'name') == 'nvidia-device-plugin' }
  check(ds.dig('metadata', 'name') == 'nvidia-device-plugin' && ds.dig('metadata', 'namespace') == 'kube-system', 'NVIDIA identity changed')
  pod = ds.dig('spec', 'template', 'spec')
  check(pod['nodeSelector'] == {'kubernetes.io/os'=>'linux', 'workload-type'=>'gpu'} && !pod['affinity'], 'NVIDIA placement must rely on existing GPU labels')
  check(pod.fetch('tolerations').include?({'key'=>'nvidia.com/gpu', 'operator'=>'Equal', 'value'=>'true', 'effect'=>'NoSchedule'}), 'NVIDIA GPU taint not tolerated')
  container = pod.fetch('containers').first
  check(container['image'] == 'nvcr.io/nvidia/k8s-device-plugin:v0.20.0', 'NVIDIA image version changed')
  check(container.dig('resources', 'requests') == {'cpu'=>'50m', 'memory'=>'64Mi'}, 'NVIDIA request budget changed')
  check(pod.fetch('containers').all? { |c| %w[requests limits].all? { |k| !c.dig('resources', k, 'nvidia.com/gpu') } }, 'Device plugin must not reserve GPU')
  flags = container.fetch('env').to_h { |e| [e['name'], e['value']] }
  check(flags['FAIL_ON_INIT_ERROR'] == 'true' && flags['MIG_STRATEGY'] == 'none' && flags['DEVICE_LIST_STRATEGY'] == 'envvar', 'NVIDIA discovery/exclusive allocation contract changed')
  check(pod.fetch('volumes').any? { |v| v.dig('hostPath', 'path') == '/var/lib/kubelet/device-plugins' }, 'kubelet registration socket missing')
  puts "#{environment}: cluster addons rendering, TLS, resource budget and Argo permissions PASS"
end
