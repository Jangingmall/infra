#!/usr/bin/env ruby
require 'yaml'
require 'open3'

if ARGV == ['--help']
  puts 'Usage: ruby scripts/validate-workload-secrets.rb [repository-root]'
  puts 'Checks commented SSM registration lists and IRSA against rendered Kubernetes manifests; no AWS access.'
  exit
end
abort 'Usage: ruby scripts/validate-workload-secrets.rb [repository-root]' if ARGV.length > 1 || ARGV.any? { |v| v.start_with?('-') }
root = ARGV.empty? ? File.expand_path('..', __dir__) : File.expand_path(ARGV.fetch(0))

def check(condition, message)
  abort "FAIL: #{message}" unless condition
end

def quoted_list(body, attribute)
  match = body.match(/\b#{Regexp.escape(attribute)}\s*=\s*\[([^\]]*)\]/m)
  check(match, "missing #{attribute} list")
  match[1].scan(/"([^"]+)"/).flatten
end

bindings = {
  'backend' => ['app', 'backend-sa', 'backend', ['backend-config']],
  'ai' => ['ai', 'ai-worker-sa', 'ai', ['ai-sglang-config', 'ai-chatbot-config']],
  'redis' => ['app', 'redis-sa', 'redis', ['redis-config']],
  'ai-vector-db' => ['ai', 'ai-vector-db-sa', 'ai_vector_db', ['ai-vector-db-config']]
}

# 역할별로 허용되는 kms:ViaService.
# backend 만 s3 를 포함한다 — s3-returns 가 SSE-KMS(CMK) 버킷이기 때문.
# ai 는 s3-models 가 AES256 이라 ssm 만으로 충분하다.
via_services = {
  'backend' => %w[s3.ap-northeast-2.amazonaws.com ssm.ap-northeast-2.amazonaws.com],
  'ai' => %w[ssm.ap-northeast-2.amazonaws.com],
  'redis' => %w[ssm.ap-northeast-2.amazonaws.com],
  'ai-vector-db' => %w[ssm.ap-northeast-2.amazonaws.com]
}

%w[staging prod].each do |environment|
  overlay = environment == 'staging' ? 'stage' : 'prod'
  manifests, error, status = Open3.capture3('kubectl', 'kustomize', File.join(root, 'k8s/overlays', overlay))
  check(status.success?, "#{environment}: kustomize failed: #{error}")
  documents = YAML.load_stream(manifests).compact
  providers = documents.select { |d| d['kind'] == 'SecretProviderClass' }
  parameters = providers.to_h do |provider|
    objects = YAML.safe_load(provider.dig('spec', 'parameters', 'objects'))
    [[provider.dig('metadata', 'namespace'), provider.dig('metadata', 'name')], objects.map { |o| o.fetch('objectName') }]
  end

  directory = File.join(root, 'terraform/environments', environment)
  example = File.read(File.join(directory, 'terraform.tfvars.example'))
  check(example.match?(/^env\s*=\s*"#{environment}"/), "#{environment}: example env mismatch")
  check(!example.match?(/^(backend|ai)_ssm_parameters\s*=/), "#{environment}: parameter examples must remain commented")
  expected_parameters = %w[backend ai].flat_map do |team|
    map = example.match(/^# #{team}_ssm_parameters\s*=\s*\{(.*?)^# \}/m)
    check(map, "#{environment}: missing commented #{team} registration list")
    map[1].scan(/^#\s+"([^"]+)"\s*=/).flatten.map { |key| "/#{environment}/#{team}/#{key}" }
  end
  check(expected_parameters.sort == parameters.values.flatten.uniq.sort,
        "#{environment}: commented registration keys must exactly match SecretProviderClass paths")
  ssm = File.read(File.join(directory, 'ssm.tf'))
  check(ssm.lines.all? { |line| line.strip.empty? || line.lstrip.start_with?('#') },
        "#{environment}: ssm.tf must remain commented for direct registration")

  irsa = File.read(File.join(directory, 'irsa.tf'))
  bindings.each do |role, (namespace, account, policy, provider_names)|
    binding = irsa.match(/^    #{Regexp.escape(role)}\s*=\s*\{(.*?)^    \}/m)
    check(binding, "#{environment}: missing role #{role}")
    check(binding[1].match?(/namespace\s*=\s*"#{namespace}"/) &&
          binding[1].match?(/service_account\s*=\s*"#{account}"/) &&
          binding[1].match?(/policy_json\s*=\s*data\.aws_iam_policy_document\.#{policy}\.json/) &&
          binding[1].match?(/create_policy\s*=\s*true/) &&
          binding[1].match?(/managed_policy_arns\s*=\s*\[\s*\]/), "#{environment}: #{role} binding/policy mismatch")
    check(documents.any? { |d| d['kind'] == 'ServiceAccount' && d.dig('metadata', 'namespace') == namespace && d.dig('metadata', 'name') == account },
          "#{environment}: missing ServiceAccount #{namespace}/#{account}")
    provider_names.each do |name|
      check(documents.any? do |d|
        spec = d.dig('spec', 'template', 'spec')
        d.dig('metadata', 'namespace') == namespace && spec && spec['serviceAccountName'] == account &&
          Array(spec['volumes']).any? { |v| v.dig('csi', 'volumeAttributes', 'secretProviderClass') == name }
      end, "#{environment}: #{name} is not mounted by #{account}")
    end

    body = irsa.match(/^data "aws_iam_policy_document" "#{policy}" \{(.*?)^\}/m)
    check(body, "#{environment}: missing policy #{policy}")
    statements = body[1].scan(/^  statement \{(.*?)^  \}/m).flatten
    read = statements.select { |s| quoted_list(s, 'actions').any? { |a| a.start_with?('ssm:') || a == '*' } }
    check(read.size == 1 && read[0].match?(/effect\s*=\s*"Allow"/), "#{environment}: #{role} must have one SSM Allow statement")
    actions = quoted_list(read[0], 'actions')
    check(actions.include?('ssm:GetParameters') && (actions - %w[ssm:GetParameter ssm:GetParameters ssm:GetParametersByPath]).empty?,
          "#{environment}: #{role} needs CSI GetParameters with read-only SSM permissions")
    resources = quoted_list(read[0], 'resources').map do |value|
      value.gsub('${var.env}', environment).gsub('${var.region}', 'ap-northeast-2')
           .gsub('${data.aws_caller_identity.current.account_id}', '111122223333')
    end
    prefix = 'arn:aws:ssm:ap-northeast-2:111122223333:parameter'
    paths = provider_names.flat_map { |name| parameters.fetch([namespace, name]) }.uniq
    check(paths.all? { |path| resources.any? { |r| File.fnmatch?(r, prefix + path) } },
          "#{environment}: #{role} cannot read every mounted parameter")
    expected = role == 'backend' ? ["/#{environment}/backend/*", "/#{environment}/ai/internal-auth-token"] : paths
    check(resources.sort == expected.map { |path| prefix + path }.sort,
          "#{environment}: #{role} grants extra or cross-environment/account access")

    kms_statements = statements.select { |s| quoted_list(s, 'actions').any? { |a| a.start_with?('kms:') || a == '*' } }
    check(kms_statements.size == 1, "#{environment}: #{role} must have exactly one scoped KMS statement")
    kms = kms_statements.first
    check(kms.match?(/effect\s*=\s*"Allow"/) && quoted_list(kms, 'actions').include?('kms:Decrypt') &&
          (quoted_list(kms, 'actions') - %w[kms:Decrypt kms:GenerateDataKey]).empty? &&
          kms.match?(/resources\s*=\s*\[module\.kms_app\.key_arn\]/) &&
          kms.include?('"kms:ViaService"') && kms.include?('"StringEquals"') &&
          quoted_list(kms, 'values').map { |v| v.gsub('${var.region}', 'ap-northeast-2') }.sort == via_services.fetch(role).sort,
          "#{environment}: #{role} needs KMS decrypt restricted to the app key via SSM")
    if %w[redis ai-vector-db].include?(role)
      check(statements.size == 2 && quoted_list(kms, 'actions') == ['kms:Decrypt'],
            "#{environment}: #{role} must only read its parameters and decrypt")
    end
  end
  puts "PASS: #{environment}: #{expected_parameters.size} parameters, four ServiceAccount/CSI/IRSA bindings, scoped SSM/KMS access"
end
puts 'Static contract checks passed. AWS IAM evaluation, CSI mounts and application connections require EKS verification.'
