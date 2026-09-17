#!/usr/bin/env ruby
require 'yaml'
require 'ipaddr'
require 'open3'
require 'tmpdir'

usage = 'Usage: ruby scripts/validate-tempo.rb stage|prod RENDER_DIRECTORY'
if ARGV == ['--help']
  puts usage
  exit
end
environment, directory = ARGV
abort usage unless ARGV.size == 2 && %w[stage prod].include?(environment)
def check(condition, message)
  abort "Tempo validation failed: #{message}" unless condition
end
def documents(path)
  YAML.load_stream(File.read(path)).compact
end
resources = documents(File.join(directory, 'tempo.yaml'))
find = ->(kind, name) { resources.find { |r| r['kind'] == kind && r.dig('metadata', 'name') == name } || abort("Missing #{kind}/#{name}") }
app = documents(File.join(directory, 'applications.yaml')).find { |r| r['kind'] == 'Application' && r.dig('metadata', 'name') == "#{environment}-observability-tempo" }
check(app && !app.dig('metadata', 'finalizers'), 'Application missing or cascading deletion enabled')
check(app.dig('spec', 'syncPolicy', 'automated', 'enabled') == false && app.dig('spec', 'syncPolicy', 'automated', 'prune') == false, 'first deployment must be manual without auto-prune')
source = app.dig('spec', 'sources', 0)
check(source['repoURL'] == 'https://grafana-community.github.io/helm-charts' && source['targetRevision'] == '2.4.0', 'chart pin differs')
stateful = find.call('StatefulSet', 'tempo')
pod = stateful.dig('spec', 'template', 'spec')
check(stateful.dig('spec', 'replicas') == 1 && pod['containers'].size == 1, 'single instance/container budget changed')
check(pod.dig('nodeSelector', 'workload-type') == 'system', 'Tempo must run on System nodes')
check(pod['serviceAccountName'] == 'tempo-sa' && pod['automountServiceAccountToken'] == false, 'IRSA identity or API token changed')
container = pod['containers'].first
check(container['image'] == 'docker.io/grafana/tempo:2.10.8', 'image pin differs')
check(container.dig('resources', 'requests') == {'cpu'=>'250m', 'memory'=>'768Mi'}, 'requests budget changed')
check(container.dig('securityContext', 'readOnlyRootFilesystem') && pod.dig('securityContext', 'runAsNonRoot'), 'read-only/non-root protection missing')
check(container['args'].include?('-config.expand-env=true') && container['args'].include?('-mem-ballast-size-mbs=0'), 'runtime expansion or bounded memory configuration missing')
env = container.fetch('env').to_h { |e| [e['name'], e] }
check(env.dig('AWS_EC2_METADATA_DISABLED', 'value') == 'true', 'node role fallback must stay disabled')
check(env.dig('TEMPO_S3_BUCKET', 'valueFrom', 'configMapKeyRef') == {'name'=>'tempo-runtime', 'key'=>'TEMPO_S3_BUCKET'}, 'bucket must be a required runtime reference')
check(env.keys.none? { |key| %w[AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN].include?(key) }, 'static credentials prohibited')
pvc = stateful.dig('spec', 'volumeClaimTemplates', 0)
check(pvc.dig('spec', 'storageClassName') == 'gp3-monitoring' && pvc.dig('spec', 'resources', 'requests', 'storage') == '10Gi', 'WAL PVC changed')
check(!stateful.dig('spec', 'persistentVolumeClaimRetentionPolicy'), 'PVC auto-deletion prohibited')
check(stateful.dig('metadata','annotations','argocd.argoproj.io/sync-options') == 'Prune=confirm,Delete=confirm', 'storage workload deletion guard missing')
config = YAML.load(find.call('ConfigMap', 'tempo').dig('data', 'tempo.yaml'))
check(config.dig('distributor','receivers') == {'otlp'=>{'protocols'=>{'grpc'=>{'endpoint'=>'0.0.0.0:4317'}}}}, 'only OTLP gRPC receiver is allowed')
check(config.dig('compactor','compaction','block_retention') == (environment == 'stage' ? '72h' : '168h'), 'retention differs')
s3 = config.dig('storage','trace','s3')
check(config.dig('storage','trace','backend') == 's3' && s3['bucket'] == '${TEMPO_S3_BUCKET}', 'S3 runtime storage missing')
check(s3['prefix'] == "tempo/#{environment == 'stage' ? 'staging' : 'prod'}" && s3['insecure'] == false, 'environment prefix or HTTPS differs')
check(!s3['access_key'] && !s3['secret_key'] && !config['metrics_generator'], 'static keys or extra metrics generator introduced')
check(config.dig('querier','max_concurrent_queries') == 2 && config.dig('query_frontend','search','concurrent_jobs') == 2, 'query concurrency is unbounded')
shards = config.dig('query_frontend','trace_by_id','query_shards') || 50
check(shards < config.dig('query_frontend','max_outstanding_per_tenant'), 'one trace query can exhaust the frontend queue')
check(resources.none? { |r| r['kind'] == 'Ingress' || (r['kind'] == 'Service' && r.dig('spec','type') != 'ClusterIP') }, 'Tempo must not be exposed outside the cluster')
check(find.call('ServiceMonitor', 'tempo').dig('metadata','labels','release') == 'metrics', 'metrics selector mismatch')
policy = find.call('NetworkPolicy', 'tempo').fetch('spec')
check(policy['policyTypes'].sort == %w[Egress Ingress], 'both network directions must be isolated')
expected_ingress = {
  'otel-collector'=>[4317], 'grafana'=>[3200], 'prometheus'=>[3200], 'tempo'=>[9095,7946,7946]
}
actual_ingress = {}
policy.fetch('ingress').each do |rule|
  rule.fetch('from').each do |peer|
    check(peer.keys == ['podSelector'], 'Tempo ingress must stay within monitoring namespace')
    name = peer.dig('podSelector','matchLabels','app.kubernetes.io/name')
    check(name && !actual_ingress.key?(name), 'unexpected ingress selector')
    actual_ingress[name] = rule.fetch('ports').map { |p| p['port'] }
  end
end
check(actual_ingress == expected_ingress, 'unapproved inbound source/port')
policy.fetch('egress').each do |rule|
  check(rule['to'] && rule['ports'], 'unrestricted egress rule')
  rule['to'].each do |peer|
    if peer['ipBlock']
      cidr = peer.dig('ipBlock','cidr')
      begin
        ip = IPAddr.new(cidr)
        check(cidr.include?('/') && ip.prefix > 0, 'egress requires approved CIDRs')
      rescue IPAddr::InvalidAddressError
        abort "Invalid Tempo egress CIDR: #{cidr}"
      end
      check(rule['ports'] == [{'protocol'=>'TCP','port'=>443}], 'AWS egress must use HTTPS')
    else
      dns = peer.dig('namespaceSelector','matchLabels','kubernetes.io/metadata.name') == 'kube-system' && peer.dig('podSelector','matchLabels','k8s-app') == 'kube-dns'
      own = peer.dig('podSelector','matchLabels') == {'app.kubernetes.io/name'=>'tempo','app.kubernetes.io/instance'=>'tempo'} && !peer['namespaceSelector']
      check(dns || own, 'unexpected internal egress destination')
      expected = dns ? [53,53] : [9095,7946,7946]
      check(rule['ports'].map { |p| p['port'] } == expected, 'unexpected internal egress ports')
    end
  end
end

root = File.expand_path('..', __dir__)
Dir.mktmpdir('tempo-contract-') do |tmp|
  complete = {'tempoBucket'=>'tempo-contract-test', 'serviceAccount'=>{'annotations'=>{'eks.amazonaws.com/role-arn'=>'arn:aws:iam::123456789012:role/tempo-contract-test'}}, 'tempoEgressCidrs'=>['192.0.2.0/24']}
  cases = {'empty'=>[{},true], 'complete'=>[complete,true], 'missing-role'=>[complete.merge('serviceAccount'=>{}),false], 'all-internet'=>[complete.merge('tempoEgressCidrs'=>['0.0.0.0/0']),false]}
  cases.each do |name, (values, success)|
    file = File.join(tmp, "#{name}.yaml")
    File.write(file, values.to_yaml)
    output, error, status = Open3.capture3('helm','template','tempo-assets',File.join(root,'platform/observability'),'-n','monitoring','--set','bundle=tempo','--set',"environment=#{environment}",'-f',file)
    check(status.success? == success, "runtime case #{name}: #{error}")
    next unless success
    docs = YAML.load_stream(output).compact
    runtime = docs.find { |r| r.dig('metadata','name') == 'tempo-runtime' }
    check(name == 'empty' ? !runtime : runtime.dig('data','TEMPO_S3_BUCKET') == 'tempo-contract-test', 'runtime readiness gate failed')
  end
end
puts "#{environment}: Tempo storage, identity, isolation, resource budget and runtime readiness contracts PASS"
