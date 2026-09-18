#!/usr/bin/env ruby
require 'yaml'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'pathname'

usage = 'Usage: ruby scripts/render-observability.rb stage|prod OUTPUT_DIRECTORY [--discord] [storage metrics loki alloy-pods alloy-events targets gpu ai-metrics traces tempo]'
if ARGV == ['--help']
  puts usage
  puts 'Render the actual Argo CD sources locally, without cluster access. Requires Helm, kubectl and chart repository access.'
  exit
end
environment, output, *options = ARGV
names = %w[storage metrics loki alloy-pods alloy-events targets gpu ai-metrics traces tempo]
discord = options.delete('--discord')
unless %w[stage prod].include?(environment) && output && (options - names).empty?
  warn usage
  exit 2
end
root = File.expand_path('..', __dir__)
output = File.expand_path(output)
FileUtils.mkdir_p(output)
cache = ENV.fetch('OBSERVABILITY_CHART_CACHE', File.join(output, 'charts'))
FileUtils.mkdir_p(cache)

def run(*command)
  stdout, stderr, status = Open3.capture3(*command)
  abort "#{command.first} failed: #{stderr}\n#{stdout}" unless status.success?
  stdout
end

def docs(text)
  YAML.load_stream(text).compact
end

def identity(resource, namespace)
  group = resource.fetch('apiVersion').split('/')[0...-1].join('/')
  cluster_kinds = %w[CustomResourceDefinition ClusterRole ClusterRoleBinding StorageClass MutatingWebhookConfiguration ValidatingWebhookConfiguration Namespace]
  ns = cluster_kinds.include?(resource['kind']) ? '' : resource.dig('metadata', 'namespace') || namespace
  [group, resource.fetch('kind'), ns, resource.dig('metadata', 'name')]
end

Dir.mktmpdir('observability-sources-') do |tmp|
  entry = File.join(root, 'argocd/applications', environment)
  if discord
    File.write(File.join(tmp, 'kustomization.yaml'), {
      'apiVersion'=>'kustomize.config.k8s.io/v1beta1', 'kind'=>'Kustomization',
      'resources'=>[Pathname.new(File.realpath(entry)).relative_path_from(Pathname.new(File.realpath(tmp))).to_s],
      'components'=>[Pathname.new(File.realpath(File.join(root, 'argocd/components/observability-discord', environment))).relative_path_from(Pathname.new(File.realpath(tmp))).to_s]
    }.to_yaml)
    entry = tmp
  end
  applications = docs(run('kubectl', 'kustomize', entry))
  File.write(File.join(output, 'applications.yaml'), applications.map(&:to_yaml).join)
  ownership = {}
  docs(run('kubectl', 'kustomize', File.join(root, 'k8s/overlays', environment))).each do |resource|
    ownership[identity(resource, 'monitoring')] = 'workloads'
  end
  applications.select { |a| a['kind']=='Application' && a.dig('metadata','labels','app.kubernetes.io/part-of')=='observability' }.each do |app|
    suffix = app.dig('metadata','name').delete_prefix("#{environment}-observability-")
    next unless options.empty? || options.include?(suffix)
    spec = app.fetch('spec')
    project = applications.find { |r| r['kind']=='AppProject' && r.dig('metadata','name')==spec['project'] }.fetch('spec')
    namespace = spec.dig('destination','namespace')
    effective = {}
    spec.fetch('sources').each_with_index do |source, index|
      abort "#{suffix}: source repository not authorized" unless project['sourceRepos'].include?(source['repoURL'])
      if source['chart'] || source['helm']
        if source['chart']
          chart = File.join(cache, "#{source['chart']}-#{source['targetRevision']}", source['chart'])
          unless File.directory?(chart)
            FileUtils.mkdir_p(File.dirname(chart))
            run('helm', 'pull', source['chart'], '--repo', source['repoURL'], '--version', source['targetRevision'], '--untar', '--untardir', File.dirname(chart))
          end
        else
          chart = File.join(root, source.fetch('path'))
        end
        helm = source.fetch('helm')
        args = ['--namespace', namespace]
        helm.fetch('valueFiles', []).each do |file|
          value_path = if file.start_with?('$values/')
            reference = spec['sources'].find { |s| s['ref']=='values' }
            abort 'values must reference the infra repository' unless reference && reference['repoURL']=='https://github.com/Jangingmall/infra.git'
            File.join(root, file.delete_prefix('$values/'))
          else
            File.join(chart, file)
          end
          args.concat(['--values', value_path])
        end
        if helm['valuesObject']
          inline = File.join(tmp, "#{suffix}-#{index}.yaml")
          File.write(inline, helm['valuesObject'].to_yaml)
          args.concat(['--values', inline])
        end
        run('helm', 'lint', chart, '--strict', *args)
        flags = ['--include-crds']
        flags << '--skip-tests' if helm['skipTests']
        rendered = run('helm', 'template', helm.fetch('releaseName'), chart, *args, *flags)
      elsif source['path']
        rendered = run('kubectl', 'kustomize', File.join(root, source['path']))
      else
        next
      end
      docs(rendered).each do |resource|
        key = identity(resource, namespace)
        if effective.key?(key)
          abort "Unexpected duplicate resource: #{key.join('/')}" unless suffix=='loki' && index==1 && key==['rbac.authorization.k8s.io','Role','monitoring','loki']
          puts "#{environment}/loki: Git source overrides chart Role (Argo CD last-source-wins)"
        end
        effective[key] = resource
      end
    end
    effective.each do |key, resource|
      group, kind, ns, name = key
      scope = ns.empty? ? 'clusterResourceWhitelist' : 'namespaceResourceWhitelist'
      abort "#{suffix}: #{kind} not authorized by AppProject" unless project.fetch(scope).include?({'group'=>group,'kind'=>kind})
      unless ns.empty?
        abort "#{suffix}: namespace #{ns} not authorized" unless project['destinations'].any? { |d| d['namespace']==ns && d['server']==spec.dig('destination','server') }
      end
      abort "Shared resource: #{kind}/#{name} in #{ownership[key]} and #{suffix}" if ownership.key?(key)
      ownership[key] = suffix
    end
    if suffix=='loki'
      role = effective.fetch(['rbac.authorization.k8s.io','Role','monitoring','loki'])
      abort 'Loki Role must only read ConfigMaps' unless role['rules']==[{'apiGroups'=>[''],'resources'=>['configmaps'],'verbs'=>%w[get watch list]}]
    end
    File.write(File.join(output, "#{suffix}.yaml"), effective.values.map(&:to_yaml).join)
    puts "#{environment}/#{suffix}: #{effective.size} resources rendered; project and ownership PASS"
  end
end
