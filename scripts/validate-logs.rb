#!/usr/bin/env ruby
require 'yaml'
def check(condition, message)
  abort "Logs validation failed: #{message}" unless condition
end
env, dir = ARGV
check(%w[stage prod].include?(env) && dir, 'expected stage|prod OUTPUT_DIRECTORY')
def documents(path)
  YAML.load_stream(File.read(path)).compact
end
loki = documents("#{dir}/loki.yaml")
cm = loki.find { |r| r['kind']=='ConfigMap' && r.fetch('data', {}).key?('config.yaml') }
check(cm, 'Loki config missing')
config = YAML.load(cm['data']['config.yaml'])
check(config.dig('limits_config','retention_period') == (env=='stage' ? '168h' : '336h'), 'retention differs')
check(config.dig('storage_config','object_prefix') == 'loki/', 'S3 prefix isolation missing')
check(config.dig('compactor','retention_enabled') == true, 'retention compactor disabled')
check(config.dig('compactor','delete_request_store') == 's3', 'delete request store missing')
check(config.dig('common','storage','s3','bucketnames') == '${LOKI_S3_BUCKET}', 'bucket must be supplied at runtime')
check(loki.none? { |r| r['kind']=='ClusterRole' }, 'Loki RBAC must be namespaced')
check(loki.select { |r| r['kind']=='Role' }.flat_map { |r| r['rules'] }.none? { |r| r['resources'].include?('secrets') }, 'Loki must not read Kubernetes Secrets')
state = loki.find { |r| r['kind']=='StatefulSet' && r.dig('metadata','name')=='loki' }
check(state && state.dig('spec','replicas')==1, 'single Loki instance missing')
check(state.dig('spec','template','spec','serviceAccountName')=='loki-sa', 'Loki SA differs')
check(state.dig('spec','template','spec','nodeSelector','workload-type')=='system', 'Loki placement differs')
preferences = state.dig('spec','template','spec','affinity','nodeAffinity','preferredDuringSchedulingIgnoredDuringExecution') || []
check(preferences.any? { |p| p.dig('preference','matchExpressions')&.any? { |e| e['key']=='node.kubernetes.io/instance-type' && e['operator']=='In' && e['values']==['t3.medium'] } }, 'Loki medium preference missing')
check(state.dig('spec','persistentVolumeClaimRetentionPolicy','whenDeleted') != 'Delete', 'Loki PVC auto-delete enabled')
check(loki.any? { |r| r['kind']=='Deployment' && r.dig('metadata','name')=='loki-gateway' }, 'gateway must remain')
check(state.dig('spec','template','spec','containers').any? { |c| c['name'].include?('rules') }, 'rules sidecar must remain')
%w[pods events].each do |kind|
  docs = documents("#{dir}/alloy-#{kind}.yaml")
  workload = docs.find { |r| r['kind']==(kind=='pods' ? 'DaemonSet' : 'Deployment') }
  check(workload, "#{kind} workload missing")
  pod = workload.dig('spec','template','spec')
  alloy = pod['containers'].find { |c| c['name']=='alloy' }
  environment = alloy.fetch('env').find { |e| e['name']=='OBS_ENV' }
  check(environment && environment['value']==env, 'Alloy environment differs')
  check(pod['volumes'].any? { |v| v.dig('configMap','name')=="alloy-#{kind}-config" }, 'Git config is not mounted')
  reloader = pod['containers'].find { |c| c['name']=='config-reloader' }
  check(reloader && reloader['args'].include?('--watched-dir=/etc/alloy'), 'external config reload missing')

  if kind=='events'
    check(workload.dig('spec','replicas')==1 && workload.dig('spec','strategy','type')=='Recreate', 'Events must not overlap during rollout')
  end
  rules = docs.select { |r| r['kind']=='Role' }.flat_map { |r| r['rules'] }
  check(rules.all? { |r| r['verbs'].sort==%w[get list watch] && r['resources']==[kind=='pods' ? 'pods' : 'events'] }, 'Alloy RBAC is broader than required')
  source = docs.find { |r| r['kind']=='ConfigMap' }.fetch('data').values.join
  check(source.include?('batch_size = "256KiB"') && source.include?('max_backoff_retries = 3'), 'shared log buffer missing')
  check(source.include?('loki.source.kubernetes_events') == (kind=='events'), 'Events collected by wrong workload')
end
(loki + documents("#{dir}/alloy-pods.yaml") + documents("#{dir}/alloy-events.yaml")).each do |r|
  check(r['kind']!='Ingress', 'public Ingress found')
  check([nil,'ClusterIP'].include?(r.dig('spec','type')), 'public Service found') if r['kind']=='Service'
end
puts "#{env}: Loki retention/prefix, retained gateway, Alloy RBAC and Events singleton PASS"
