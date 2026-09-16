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
