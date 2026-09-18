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
  expected_names = %w[workloads cloudnative-pg argo-rollouts secrets-store-csi backend-networking cert-manager barman-cloud cnpg-backup].map { |n| "#{environment}-#{n}" } +
    %w[storage metrics loki alloy-pods alloy-events targets gpu ai-metrics traces tempo].map { |n| "#{environment}-observability-#{n}" }
  check(applications.map { |a| a.dig('metadata', 'name') }.sort == expected_names.sort, "#{environment}: Application inventory differs")
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
  backend = managed.find { |r| r['kind']=='Rollout' && r.dig('metadata','name')=='backend' }.fetch('spec')
  hpa = managed.find { |r| r['kind']=='HorizontalPodAutoscaler' && r.dig('metadata','name')=='backend' }.fetch('spec')
  check(hpa['minReplicas']==2 && hpa['maxReplicas']==4, 'Backend HPA must retain the agreed 2..4 range')
  check(backend['replicas']==2 && backend.dig('strategy','blueGreen','previewReplicaCount')==1, 'Backend rollout exceeds initial capacity contract')
  pod = backend.dig('template','spec')
  container = pod.fetch('containers').find { |c| c['name']=='backend' }
  check(container.dig('resources','requests')=={'cpu'=>'700m','memory'=>'1Gi'}, 'Backend scheduling budget differs')
  check(container.dig('resources','limits','memory')=='4Gi', 'Backend must retain the existing memory limit until load testing supports a change')
  jvm_options = container.fetch('env').select { |e| %w[JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS _JAVA_OPTIONS].include?(e['name']) }
  check(jvm_options.none? { |e| e.fetch('value', '').match?(/-Xmx|-XX:MaxHeapSize=/) }, 'Backend must use image percentage sizing without an infra fixed heap override')
  warn "#{environment}: capacity warning: HPA 4 + Preview needs 5 Pods; two medium App nodes fit at most four 700m Backend Pods. Reserve rollout capacity before deployment."
spc = managed.find { |r| r['kind']=='SecretProviderClass' && r.dig('metadata','name')=='ai-vector-db-config' }
check(spc, 'AI vector DB SecretProviderClass missing')
check(spc.dig('spec','parameters','usePodIdentity')=='false', 'AI vector DB must use IRSA')
objects = YAML.load(spc.dig('spec','parameters','objects'))
prefix = environment=='stage' ? 'staging' : 'prod'
check(objects.map { |o| o['objectName'] }.sort == %W[/#{prefix}/ai/vector-db/password /#{prefix}/ai/vector-db/postgres-password], 'AI secret environment paths differ')
check(!spc.dig('spec','secretObjects'), 'AI DB must not sync Kubernetes Secrets')
chat = managed.find { |r| r['kind']=='SecretProviderClass' && r.dig('metadata','name')=='ai-chatbot-config' }
check(chat && !chat.dig('spec','secretObjects'), 'AI chatbot must use file-only secrets')
chat_objects = YAML.load(chat.dig('spec','parameters','objects'))
check(chat_objects.map { |o| o['objectName'] } == ["/#{prefix}/ai/vector-db/password"], 'AI must mount only application password')
ai = managed.find { |r| r['kind']=='Deployment' && r.dig('metadata','name')=='ai-ollama' }.dig('spec','template','spec')
check(ai['volumes'].any? { |v| v.dig('csi','volumeAttributes','secretProviderClass')=='ai-chatbot-config' }, 'AI CSI volume missing')
check(ai['containers'].first['env'].any? { |e| e['name']=='DB_PASSWORD_FILE' && e['value']=='/mnt/secrets-store/password' }, 'AI password file contract missing')
check(ai['containers'].first['volumeMounts'].any? { |v| v['name']=='ai-chatbot-secrets' && v['readOnly']==true }, 'AI CSI mount missing')
db = managed.find { |r| r['kind']=='StatefulSet' && r.dig('metadata','name')=='ai-vector-db' }.dig('spec','template','spec')
check(db['serviceAccountName']=='ai-vector-db-sa', 'AI DB IRSA ServiceAccount missing')
check(db['volumes'].any? { |v| v.dig('csi','volumeAttributes','secretProviderClass')=='ai-vector-db-config' }, 'AI secret sync needs CSI volume')
check(db['containers'].first['volumeMounts'].any? { |v| v['name']=='ai-vector-db-secrets' && v['readOnly']==true }, 'AI secret sync needs mounted volume')
check(db['containers'].first['env'].any? { |e| e['name']=='POSTGRES_PASSWORD_FILE' && e['value']=='/mnt/secrets-store/postgres-password' }, 'DB password file missing')
check(db['containers'].first['env'].any? { |e| e['name']=='AI_DB_PASSWORD_FILE' && e['value']=='/mnt/secrets-store/password' }, 'DB application password file missing')
[db, ai].each do |pod|
  check(pod['containers'].all? { |c| c.fetch('env',[]).none? { |e| e.dig('valueFrom','secretKeyRef','name')=='ai-vector-db-auth' } }, 'obsolete AI Secret reference remains')
end
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

rollouts = documents("#{render_dir}/argo-rollouts.yaml")
check(rollouts.none? { |r| %w[Deployment Service].include?(r['kind']) && r.dig('metadata', 'name').include?('dashboard') }, 'Rollouts Dashboard must not run continuously')
controller = rollouts.find { |r| r['kind'] == 'Deployment' && !r.dig('metadata', 'name').include?('dashboard') }
check(controller && controller.dig('spec', 'replicas') == 2, 'Rollouts Controller replicas must remain 2')
puts 'Argo Rollouts: Controller retained, Dashboard disabled PASS'
