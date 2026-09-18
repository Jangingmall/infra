#!/usr/bin/env ruby
# 실제 Helm 출력에서 Discord 설정과 CSI/IRSA 계약을 확인한다. AWS/Discord에는 접근하지 않는다.
require 'yaml'
require 'base64'
def check(value, message)
  abort "Alerting validation failed: #{message}" unless value
end
env, path, out = ARGV
check(%w[stage prod].include?(env) && path && out, 'expected environment, rendered manifest, output directory')
docs=YAML.load_stream(File.read(path)).compact
am=docs.find{|r|r['kind']=='Alertmanager'}
sa=docs.find{|r|r['kind']=='ServiceAccount' && r.dig('metadata','name')=='alertmanager-sa'}
check(am && sa && am.dig('spec','serviceAccountName')=='alertmanager-sa','dedicated ServiceAccount missing')
check(sa['automountServiceAccountToken']==false,'unnecessary Kubernetes API token mounted')
check(!sa.dig('metadata','annotations','eks.amazonaws.com/role-arn'), 'do not bake a real or fabricated ARN into defaults')
volume=am.dig('spec','volumes').find{|v|v['name']=='discord-webhook'}
check(volume.dig('csi','driver')=='secrets-store.csi.k8s.io' && volume.dig('csi','readOnly')==true && volume.dig('csi','volumeAttributes','secretProviderClass')=='monitoring-discord','CSI volume mismatch')
check(am.dig('spec','volumeMounts').any?{|v|v['name']=='discord-webhook' && v['mountPath']=='/mnt/alertmanager-secrets' && v['readOnly']==true && !v['subPath']},'directory mount must be read-only and rotateable')
spc=docs.find{|r|r['kind']=='SecretProviderClass'}
check(spc && spc.dig('metadata','namespace')=='monitoring' && !spc.dig('spec','secretObjects'),'Webhook must not be copied to Kubernetes Secret')
params=spc.dig('spec','parameters')
check(params['usePodIdentity']=='false' && params['region']=='ap-northeast-2','IRSA/region contract mismatch')
obj=YAML.load(params['objects'])
expected="/#{env=='stage' ? 'staging' : 'prod'}/monitoring/discord-webhook-url"
check(obj.size==1 && obj[0]['objectName']==expected && obj[0]['objectAlias']=='discord-webhook-url' && obj[0]['objectType']=='ssmparameter','SSM environment/path mismatch')
secret=docs.find{|r|r['kind']=='Secret' && r.dig('data','alertmanager.yaml')}
config=YAML.load(Base64.decode64(secret.dig('data','alertmanager.yaml')))
check(config.dig('route','receiver')=='null','unknown environment must be dropped')
route=config.dig('route','routes').fetch(0)
check(route['matchers'].include?("environment=\"#{env}\"") && route['matchers'].include?('notify="discord"'),'environment/opt-in routing missing')
check(config.dig('route','repeat_interval')=='2h' && route.dig('routes',0,'repeat_interval')=='30m','repeat intervals mismatch')
receiver=config['receivers'].find{|r|r['name']=='discord'}
check(receiver && receiver['discord_configs'].size==1,'native Discord receiver missing')
endpoint=receiver['discord_configs'].first
check(endpoint['webhook_url_file']=='/mnt/alertmanager-secrets/discord-webhook-url' && !endpoint['webhook_url'] && endpoint['send_resolved']==true,'file-based URL/resolved contract mismatch')
check(config['inhibit_rules'].first['equal'].include?('revision') && config['inhibit_rules'].first['equal'].include?('persistentvolumeclaim'),'inhibition would suppress unrelated resources')
File.write("#{out}/#{env}-alertmanager.yaml",config.to_yaml)
secret['data'].select{|key,_|key.end_with?('.tmpl')}.each{|key,val|File.write("#{out}/#{key}",Base64.decode64(val))}
puts "#{env}: native Discord routing, dedicated IRSA ServiceAccount and CSI file-only mount PASS"
