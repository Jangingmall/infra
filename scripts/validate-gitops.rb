#!/usr/bin/env ruby
# Rendered resource contracts: catch reconciliation conflicts and wrong environment paths.
require 'yaml'

def check(condition, message)
  abort "GitOps validation failed: #{message}" unless condition
end

def documents(path)
  YAML.load_stream(File.read(path)).compact
end

render_dir = ARGV.fetch(0)
%w[stage prod].each do |environment|
  resources = documents("#{render_dir}/argocd-#{environment}.yaml")
  applications = resources.select { |r| r['kind'] == 'Application' }
  check(applications.size == 4, "#{environment}: four Applications required")
  applications.each do |app|
    spec = app.fetch('spec')
    project = resources.find { |r| r['kind'] == 'AppProject' && r.dig('metadata', 'name') == spec['project'] }
    check(project, "#{environment}: missing AppProject")
    check(project.dig('spec', 'destinations').include?(spec['destination']), "#{environment}: destination not authorized")
    sources = spec['sources'] || [spec['source']]
    sources.each do |source|
      check(project.dig('spec', 'sourceRepos').include?(source['repoURL']), 'repository not authorized')
    end
    check(spec.dig('destination', 'server') == 'https://kubernetes.default.svc', 'only local cluster is allowed')
    check(!app.dig('metadata', 'finalizers'), 'Application deletion must not cascade')
  end
  workload = applications.find { |a| a.dig('metadata', 'name') == "#{environment}-workloads" }.fetch('spec')
  check(workload.dig('source', 'path') == "k8s/overlays/#{environment}", 'wrong overlay')
  check(workload.dig('source', 'targetRevision') == 'main', 'wrong Git revision')
  policy = workload.fetch('syncPolicy')
  check(policy['automated'] == {'enabled'=>true, 'prune'=>true, 'selfHeal'=>true, 'allowEmpty'=>false}, 'auto-sync policy changed')
  check(policy['syncOptions'].include?('RespectIgnoreDifferences=true'), 'ignored fields would still be overwritten')
  ignores = workload.fetch('ignoreDifferences')
  check(ignores.any? { |r| r['kind']=='Rollout' && r['name']=='backend' && r['jsonPointers']==['/spec/replicas'] }, 'HPA replica ownership missing')
  %w[backend-active backend-preview].each do |name|
    check(ignores.any? { |r| r['kind']=='Service' && r['name']==name && r['jsonPointers']==['/spec/selector/rollouts-pod-template-hash'] }, 'Rollouts Service selector ownership missing')
  end
  managed = documents("#{render_dir}/#{environment}.yaml")
spc = managed.find { |r| r['kind']=='SecretProviderClass' && r.dig('metadata','name')=='ai-vector-db-config' }
check(spc, 'AI vector DB SecretProviderClass missing')
check(spc.dig('spec','parameters','usePodIdentity')=='false', 'AI vector DB must use IRSA')
objects = YAML.load(spc.dig('spec','parameters','objects'))
prefix = environment=='stage' ? 'staging' : 'prod'
check(objects.map { |o| o['objectName'] }.sort == %W[/#{prefix}/ai/vector-db/password /#{prefix}/ai/vector-db/postgres-password], 'AI secret environment paths differ')
synced = spc.dig('spec','secretObjects').first
check(synced['secretName']=='ai-vector-db-auth', 'AI Secret name differs')
check(synced['data'].map { |d| [d['objectName'],d['key']] }.sort == [['password','password'],['postgres-password','postgres-password']], 'AI Secret alias/key mismatch')
db = managed.find { |r| r['kind']=='StatefulSet' && r.dig('metadata','name')=='ai-vector-db' }.dig('spec','template','spec')
check(db['serviceAccountName']=='ai-vector-db-sa', 'AI DB IRSA ServiceAccount missing')
check(db['volumes'].any? { |v| v.dig('csi','volumeAttributes','secretProviderClass')=='ai-vector-db-config' }, 'AI secret sync needs CSI volume')
check(db['containers'].first['volumeMounts'].any? { |v| v['name']=='ai-vector-db-secrets' && v['readOnly']==true }, 'AI secret sync needs mounted volume')
  managed.each do |r|
    group = r['apiVersion'].include?('/') ? r['apiVersion'].split('/').first : ''
    scope = r.dig('metadata','namespace') ? 'namespaceResourceWhitelist' : 'clusterResourceWhitelist'
    project = resources.find { |p| p.dig('metadata','name') == "#{environment}-workloads" }
    check(project.dig('spec',scope).include?({'group'=>group,'kind'=>r['kind']}), "unauthorized workload kind #{r['kind']}")
    next unless %w[Namespace StorageClass Cluster StatefulSet].include?(r['kind'])
    check(r.dig('metadata','annotations','argocd.argoproj.io/sync-options') == 'Prune=confirm,Delete=confirm', "#{r['kind']}: data deletion guard missing")
  end
  puts "#{environment}: destinations, permissions, auto-sync, HPA/Rollouts ownership and deletion guards PASS"
end

chart = documents("#{render_dir}/argocd.yaml")
pods = chart.map do |r|
  r.dig('spec','template','spec') if %w[Deployment StatefulSet Job].include?(r['kind'])
end.compact
check(!pods.empty?, 'Argo CD chart has no workloads')
pods.each { |pod| check(pod.dig('nodeSelector','workload-type')=='system', 'Argo CD component not on System nodes') }
check(chart.none? { |r| r['kind']=='Ingress' || (r['kind']=='Service' && %w[LoadBalancer NodePort].include?(r.dig('spec','type'))) }, 'Argo CD exposed publicly')
puts 'Argo CD: System placement and internal-only services PASS'
