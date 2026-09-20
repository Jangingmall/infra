#!/usr/bin/env ruby
require 'yaml'
require 'ipaddr'
require 'open3'
require 'tmpdir'

usage = 'Usage: ruby scripts/validate-networking.rb [--help]'
if ARGV == ['--help']
  puts usage
  puts 'Render Stage/Prod entrypoints and check allowed/denied policy cases locally. No cluster access.'
  exit
end
abort usage unless ARGV.empty?
Dir.chdir(File.expand_path('..', __dir__))
def check(ok, message)
  abort "Networking validation failed: #{message}" unless ok
end
def run(*args)
  out, err, status = Open3.capture3(*args)
  check(status.success?, "#{args.first}: #{err}")
  out
end
def docs(text)
  YAML.load_stream(text).compact
end
def selected?(selector, labels)
  selector.fetch('matchLabels', {}).all? { |k,v| labels[k] == v } &&
    selector.fetch('matchExpressions', []).all? do |exp|
      check(exp['operator'] == 'In', 'test selector needs explicit support for new operator')
      exp['values'].include?(labels[exp['key']])
    end
end
# This checks manifest intent, not CNI enforcement or source NAT behavior.
def ingress_allowed?(policies, ns, labels, source_ns, source_labels, ip, port)
  selected = policies.select { |p| p.dig('metadata','namespace') == ns && p.dig('spec','policyTypes').include?('Ingress') && selected?(p.dig('spec','podSelector'), labels) }
  return true if selected.empty?
  selected.any? do |p|
    p.dig('spec').fetch('ingress', []).any? do |rule|
      rule.fetch('ports', [{'port'=>port}]).any? { |entry| entry['port'] == port && entry.fetch('protocol','TCP') == 'TCP' } &&
        rule.fetch('from', [{}]).any? do |peer|
          if peer['ipBlock']
            block = peer['ipBlock']
            IPAddr.new(block['cidr']).include?(ip) && block.fetch('except', []).none? { |cidr| IPAddr.new(cidr).include?(ip) }
          else
            namespace_ok = peer['namespaceSelector'] ? selected?(peer['namespaceSelector'], {'kubernetes.io/metadata.name'=>source_ns}) : (!peer['podSelector'] || ns == source_ns)
            namespace_ok && (!peer['podSelector'] || selected?(peer['podSelector'], source_labels))
          end
        end
    end
  end
end

dir_chart = 'platform/networking'
Dir.mktmpdir('network-contract-') do |tmp|
  fixture = {'enabled'=>true, 'targetGroupARN'=>'arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:targetgroup/backend/0123456789abcdef',
    'vpcID'=>'vpc-0123456789abcdef0', 'albSourceCidrs'=>['192.0.2.0/25','192.0.2.128/25']}
  sample = File.join(tmp, 'test.yaml'); File.write(sample, fixture.to_yaml)
  %w[stage prod].each do |env|
    args = ['helm','template','backend-networking',dir_chart,'-n','app','-f',"#{dir_chart}/#{env}.yaml"]
    current = YAML.load_file("#{dir_chart}/values.yaml").merge(YAML.load_file("#{dir_chart}/#{env}.yaml") || {})
    rendered = docs(run(*args))
    if current['enabled']
      current['albSourceCidrs'].each do |cidr|
        address = IPAddr.new(cidr)
        check(address.ipv4? && address.prefix > 0, 'ALB sources must be bounded IPv4 subnet CIDRs')
      end
    else
      check(rendered.empty?, 'disabled environment must not create an ALB or isolate ingress')
    end
    default_workloads = docs(run('kubectl','kustomize',"k8s/overlays/#{env}"))
    unless current['enabled']
      default_policies = (default_workloads + rendered).select { |r| r['kind']=='NetworkPolicy' }
      check(ingress_allowed?(default_policies, 'app', {'app.kubernetes.io/name'=>'backend'}, nil, {}, '192.0.2.10', 8080), 'disabled networking must not newly isolate Backend ingress')
    end
    resources = docs(run(*args, '-f',sample))
    binding = resources.find { |r| r['kind']=='TargetGroupBinding' }
    check(binding && binding['apiVersion']=='elbv2.k8s.aws/v1beta1', 'TGB missing')
    check(resources.none? { |r| r['kind']=='Ingress' }, 'ALB must not have an Ingress owner')
    check(binding.dig('spec','serviceRef')=={'name'=>'backend-active','port'=>8080}, 'must bind active application service')
    check(binding.dig('spec','targetType')=='ip' && binding.dig('spec','targetGroupARN')==fixture['targetGroupARN'] && binding.dig('spec','vpcID')==fixture['vpcID'], 'wrong existing AWS target')
    check(!binding.dig('spec','networking'), 'SG rules belong to Terraform')
    check(binding.dig('metadata','annotations','argocd.argoproj.io/sync-options')=='Prune=confirm,Delete=confirm', 'target deregistration must require explicit pruning')
    all = resources + docs(run('kubectl','kustomize',"k8s/overlays/#{env}"))
    %w[backend platform ai-metrics].each { |part| all += docs(run('kubectl','kustomize',"platform/observability/#{part}")) }
    pod = all.find { |r| r['kind']=='Deployment' && r.dig('metadata','name')=='ai-sglang' }.dig('spec','template','spec')
    container = pod['containers'].first
    check(container.dig('startupProbe','httpGet','path')=='/health' && container.dig('livenessProbe','httpGet','path')=='/health', 'liveness must not depend on model readiness')
    check(container.dig('readinessProbe','httpGet','path')=='/health/ready' && container.dig('readinessProbe','timeoutSeconds')>=5, 'readiness must allow both model checks')
    check(container['env'].any? { |e| e['name']=='BACKEND_URL' && e['value']=='http://backend-active.app.svc.cluster.local:8080' }, 'callback must use the internal base URL; the AI client appends the generation path')
    check(container['command']==['/bin/sh','/etc/ai-startup/start.sh'], 'CSI token wrapper not connected')
    startup = all.find { |r| r['kind']=='ConfigMap' && r.fetch('data',{}).key?('start.sh') }
    check(pod['volumes'].any? { |v| v.dig('configMap','name')==startup.dig('metadata','name') }, 'startup script hash must restart Pod')
    check(pod['volumes'].any? { |v| v.dig('csi','volumeAttributes','secretProviderClass')=='ai-sglang-config' }, 'SGLang CSI source missing')
    spc = all.find { |r| r['kind']=='SecretProviderClass' && r.dig('metadata','name')=='ai-sglang-config' }
    check(spc.dig('spec','parameters','usePodIdentity')=='false' && !spc.dig('spec','secretObjects'), 'must use IRSA and file-only secrets')
    objects = YAML.load(spc.dig('spec','parameters','objects'))
    prefix = env=='stage' ? 'staging' : 'prod'
    check(objects.map { |o| o['objectName'] }.sort==["/#{prefix}/ai/internal-auth-token", "/#{prefix}/backend/backend-auth-token"], 'wrong token parameter environment')
    backend_spc = all.find { |r| r['kind']=='SecretProviderClass' && r.dig('metadata','name')=='backend-config' }
    check(backend_spc && YAML.load(backend_spc.dig('spec','parameters','objects')).any? { |o| o['objectName']=="/#{prefix}/backend/backend-auth-token" && o['objectAlias']=='BACKEND_AUTH_TOKEN' }, 'callback token source differs between Backend and AI')
    policies = all.select { |r| r['kind']=='NetworkPolicy' }
    name = ->(value) { {'app.kubernetes.io/name'=>value} }
    backend = name.call('backend'); db = {'cnpg.io/cluster'=>'jangingmall-postgres'}
    prometheus = name.call('prometheus').merge('operator.prometheus.io/name'=>'metrics-prometheus')
    cases = [
      ['ALB application', 'app',backend,nil,{},'192.0.2.10',8080,true],
      ['ALB management denied', 'app',backend,nil,{},'192.0.2.10',9090,false],
      ['other IP denied', 'app',backend,nil,{},'198.51.100.10',8080,false],
      ['SGLang callback', 'app',backend,'ai',name.call('ai-sglang'),'10.0.16.31',8080,true],
      ['SGLang management denied', 'app',backend,'ai',name.call('ai-sglang'),'10.0.16.31',9090,false],
      ['Forged source namespace denied', 'app',backend,'app',name.call('ai-sglang'),'10.0.16.31',8080,false],
      ['AI callback denied', 'app',backend,'ai',name.call('ai-ollama'),'10.0.16.30',8080,false],
      ['Backend metrics', 'app',backend,'monitoring',prometheus,'10.0.16.10',9090,true],
      ['Backend DB', 'database',db,'app',backend,'10.0.16.20',5432,true],
      ['AI business DB denied', 'database',db,'ai',name.call('ai-ollama'),'10.0.16.30',5432,false],
      ['Ollama vector DB', 'ai',name.call('ai-vector-db'),'ai',name.call('ai-ollama'),'10.0.16.30',5432,true],
      ['SGLang vector DB denied', 'ai',name.call('ai-vector-db'),'ai',name.call('ai-sglang'),'10.0.16.31',5432,false]
    ]
    %w[ai-sglang ai-ollama].each do |ai|
      cases << ["Backend #{ai}",'ai',name.call(ai),'app',backend,'10.0.16.20',8000,true]
      cases << ["foreign #{ai} denied",'ai',name.call(ai),'app',name.call('untrusted'),'10.0.16.21',8000,false]
    end
    cases.each { |label,*input,expected| check(ingress_allowed?(policies,*input)==expected, "#{env}: #{label}") }
    apps = docs(run('kubectl','kustomize',"argocd/applications/#{env}"))
    app = apps.find { |r| r.dig('metadata','name')=="#{env}-backend-networking" }
    check(app.dig('spec','source','path')==dir_chart && app.dig('spec','source','helm','valueFiles')==['values.yaml',"#{env}.yaml"], 'wrong GitOps source')
    check(app.dig('spec','syncPolicy','automated','enabled')==false && app.dig('spec','syncPolicy','automated','prune')==false, 'network rollout must remain manual')
    puts "#{env}: TGB/active Service, readiness gate and #{cases.size} combined ingress allow/deny cases PASS"
  end
  {'missing-target'=>fixture.merge('targetGroupARN'=>''), 'invalid-target'=>fixture.merge('targetGroupARN'=>'invalid'), 'missing-vpc'=>fixture.merge('vpcID'=>''), 'missing-sources'=>fixture.merge('albSourceCidrs'=>[]), 'world-source'=>fixture.merge('albSourceCidrs'=>['0.0.0.0/0'])}.each do |label,values|
    File.write(sample, values.to_yaml)
    _, _, status = Open3.capture3('helm','template','backend-networking',dir_chart,'-n','app','-f',sample)
    check(!status.success?, "#{label} must fail before deployment")
  end
end
%w[backend ai].each do |workload|
  resources = docs(run('kubectl','kustomize',"k8s/base/network-policies/#{workload}"))
  check(resources.any? { |r| r.dig('spec','egress')&.any? { |rule| rule.fetch('ports',[]).any? { |port| port['port']==4317 } && rule.fetch('to',[]).any? { |peer| peer.dig('namespaceSelector','matchLabels','kubernetes.io/metadata.name')=='monitoring' } } }, "#{workload}: pending egress bundle loses OTLP")
end
puts 'Incomplete runtime rejected; pending Backend/AI OTLP egress retained PASS'
callback = docs(run('kubectl','kustomize','k8s/base/network-policies/ai')).find { |r| r.dig('metadata','name')=='allow-sglang-callback-egress' }
check(callback.dig('spec','podSelector','matchLabels')=={'app.kubernetes.io/name'=>'ai-sglang'}, 'callback egress must not select Ollama')
check(callback.dig('spec','egress',0,'to',0)=={'namespaceSelector'=>{'matchLabels'=>{'kubernetes.io/metadata.name'=>'app'}},'podSelector'=>{'matchLabels'=>{'app.kubernetes.io/name'=>'backend'}}} && callback.dig('spec','egress',0,'ports')==[{'protocol'=>'TCP','port'=>8080}], 'callback egress must target only Backend 8080')
puts 'SGLang probes, internal callback, file-only shared token and callback egress PASS'
