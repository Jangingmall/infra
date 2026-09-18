#!/usr/bin/env ruby
require 'yaml'
require 'open3'
require 'tmpdir'
require 'fileutils'

usage = 'Usage: ruby scripts/validate-data-services.rb [render-directory]'
if ARGV == ['--help']
  puts usage
  exit
end
abort usage if ARGV.length > 1 || ARGV.any? { |a| a.start_with?('-') }
render_dir = ARGV.first && File.expand_path(ARGV.first)
Dir.chdir(File.expand_path('..', __dir__))
def check(ok, message)
  abort "Data services validation failed: #{message}" unless ok
end
def render(*args)
  out, err, status = Open3.capture3(*args)
  check(status.success?, err)
  YAML.load_stream(out).compact
end
def find(resources, kind, name)
  resources.find { |r| r['kind']==kind && r.dig('metadata','name')==name } || abort("Missing #{kind}/#{name}")
end
%w[stage prod].each do |env|
  docs = render('kubectl','kustomize',"k8s/overlays/#{env}")
  redis = find(docs,'StatefulSet','redis')
  pod = redis.dig('spec','template','spec')
  check(pod['nodeSelector']=={'workload-type'=>'app'}, 'Redis must run on App nodes')
  check(redis.dig('spec','replicas')==1 && redis.dig('spec','persistentVolumeClaimRetentionPolicy')=={'whenDeleted'=>'Retain','whenScaled'=>'Retain'}, 'Redis persistence contract')
  check(pod['serviceAccountName']=='redis-sa', 'Redis must not share Argo CD credentials')
  check(pod.dig('securityContext','runAsNonRoot'), 'Redis must not run as root')
  config_name=pod['volumes'].find{|v| v['name']=='config'}.dig('configMap','name')
  config=find(docs,'ConfigMap',config_name).fetch('data')
  check(config['redis.conf'].include?('appendonly yes') && config['redis.conf'].include?('maxmemory-policy noeviction'), 'Auth tokens require persistence and no eviction')
  policy=find(docs,'NetworkPolicy','redis-backend-only').fetch('spec')
  peer=policy.fetch('ingress').first.fetch('from').first
  check(peer.dig('namespaceSelector','matchLabels','kubernetes.io/metadata.name')=='app' && peer.dig('podSelector','matchLabels','app.kubernetes.io/name')=='backend', 'Redis ingress must constrain both namespace and Pod')
  check(policy['egress']==[] && policy['ingress'].first['ports']==[{'protocol'=>'TCP','port'=>6379}], 'Redis must not open public/outbound ports')
  backend=find(docs,'Rollout','backend').dig('spec','template','spec','containers').first
  check(backend['env'].include?({'name'=>'REDIS_HOST','value'=>'redis.app.svc.cluster.local'}), 'Backend Redis host differs')
  prefix=env=='stage' ? 'staging' : 'prod'
  [['redis-config','password'],['backend-config','spring.data.redis.password']].each do |name,alias_name|
    spc=find(docs,'SecretProviderClass',name)
    check(!spc.dig('spec','secretObjects'), 'Redis credentials must stay file-only')
    check(spc.dig('spec','parameters','usePodIdentity')=='false','IRSA required')
    objects=YAML.load(spc.dig('spec','parameters','objects'))
    check(objects.any?{|o| o['objectName']=="/#{prefix}/backend/redis-password" && o['objectAlias']==alias_name}, 'Backend/Redis must read the same SSM password')
    check(objects.none?{|o| o['objectAlias']=='REDIS_HOST'}, 'Stale SSM Redis host source remains')
  end
  args=['helm','template','cnpg-backup','platform/cnpg-backup','-f',"platform/cnpg-backup/#{env}.yaml"]
  values=YAML.load_file('platform/cnpg-backup/values.yaml').merge(YAML.load_file("platform/cnpg-backup/#{env}.yaml"))
  default=render(*args)
  check(default.empty?, 'Backup resources must remain gated before AWS handoff') unless values['enabled']
  enabled=render(*args,'--set','enabled=true','--set',"bucket=example-#{env}-backups")
  store=find(enabled,'ObjectStore','cnpg-backup').fetch('spec')
  check(store.dig('configuration','destinationPath')=="s3://example-#{env}-backups/cnpg/#{prefix}", 'Cross-environment backup path')
  check(store['retentionPolicy']=='30d' && store.dig('configuration','s3Credentials')=={'inheritFromIAMRole'=>true}, 'Backup retention or IRSA differs')
  schedule=find(enabled,'ScheduledBackup','cnpg-daily').fetch('spec')
  check(schedule['method']=='plugin' && schedule.dig('pluginConfiguration','name')=='barman-cloud.cloudnative-pg.io', 'Backup must use plugin')
  check(schedule['schedule']=='0 0 18 * * *' && schedule['suspend']==true, 'Initial schedule must be suspended at 03:00 KST') unless values['suspend']==false
  other=env=='stage' ? 'prod' : 'staging'
  _, _, status=Open3.capture3(*args,'--set','enabled=true','--set','bucket=example-backups','--set',"prefix=cnpg/#{other}")
  check(!status.success?, 'Wrong environment prefix must fail')
  unless values['bucket'] && !values['bucket'].empty?
    _,_,status=Open3.capture3(*args,'--set','enabled=true')
    check(!status.success?, 'Empty bucket must fail')
  end
  cluster=find(docs,'Cluster','jangingmall-postgres')
  if cluster.dig('spec','plugins')
    check(values['enabled'], 'WAL archiver enabled before ObjectStore')
    sa=find(docs,'ServiceAccount','cnpg-backup-sa')
    check(sa.dig('metadata','annotations','eks.amazonaws.com/role-arn').to_s.match?(/^arn:aws:iam::\d{12}:role\/.+/), 'WAL archiver requires actual IRSA annotation')
  end
  apps=render('kubectl','kustomize',"argocd/applications/#{env}")
  %w[cert-manager barman-cloud cnpg-backup].each do |name|
    app=find(apps,'Application',"#{env}-#{name}")
    check(app.dig('spec','syncPolicy','automated','enabled')==false,'Backup infrastructure must be manually synchronized')
  end
  puts "#{env}: Redis placement/auth/persistence/network and CNPG backup gating/retention/schedule PASS"
end
Dir.mktmpdir('cnpg-component-') do |tmp|
  FileUtils.cp_r('k8s',tmp)
  path="#{tmp}/k8s/overlays/stage/kustomization.yaml"
  File.write(path,File.read(path)+"  - ../../components/cnpg-backup\n") unless File.read(path).include?("../../components/cnpg-backup")
  cluster=find(render('kubectl','kustomize',File.dirname(path)),'Cluster','jangingmall-postgres')
  check(cluster.dig('spec','plugins').first['isWALArchiver']==true && cluster.dig('spec','postgresql','parameters','archive_timeout')=='5min','Backup component must configure WAL archiving on existing Cluster')
end
if render_dir
  plugin=YAML.load_stream(File.read("#{render_dir}/plugin-barman-cloud.yaml")).compact
  check(plugin.any?{|r|r['kind']=='CustomResourceDefinition' && r.dig('metadata','name')=='objectstores.barmancloud.cnpg.io'}, 'Barman CRD missing')
  check(plugin.any?{|r|r['kind']=='Certificate'}, 'Barman mTLS certificates missing')
  %w[cert-manager plugin-barman-cloud].each do |file|
    resources=YAML.load_stream(File.read("#{render_dir}/#{file}.yaml")).compact
    resources.select{|r|%w[Deployment Job].include?(r['kind'])}.each do |r|
      check(r.dig('spec','template','spec','nodeSelector','workload-type')=='system', 'Backup controller must use System nodes')
    end
  end
end
puts 'Data services validation PASS'
