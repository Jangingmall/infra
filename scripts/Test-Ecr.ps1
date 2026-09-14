param(
    [string]$TerraformPath = 'terraform',
    [string]$PluginDir = ''
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('jangin-ecr-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

function Invoke-TerraformCheck {
    param([string]$Directory, [string[]]$Arguments)
    & $TerraformPath "-chdir=$Directory" @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Terraform failed: $($Arguments -join ' ')" }
}

foreach ($environment in @('prod', 'staging')) {
    $isolatedRoot = Join-Path $testRoot $environment
    New-Item -ItemType Directory -Path $isolatedRoot | Out-Null
    # Copy only ECR-owned files: no team backend/provider, Kubernetes, IAM or bucket resources.
    Get-ChildItem -LiteralPath (Join-Path $repoRoot "terraform/environments/$environment") -Filter 'ecr*.tf' |
        Copy-Item -Destination $isolatedRoot
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tests/ecr/versions.tf') -Destination $isolatedRoot
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tests/ecr/inputs.tftest.hcl') -Destination $isolatedRoot
    $initArgs = @('init', '-backend=false', '-input=false', '-no-color')
    if ($PluginDir) { $initArgs += "-plugin-dir=$PluginDir" }
    Invoke-TerraformCheck -Directory $isolatedRoot -Arguments $initArgs
    Invoke-TerraformCheck -Directory $isolatedRoot -Arguments @('fmt', '-check')
    Invoke-TerraformCheck -Directory $isolatedRoot -Arguments @('validate', '-no-color')
    Invoke-TerraformCheck -Directory $isolatedRoot -Arguments @('test', '-no-color')
}
Write-Output "Both environment ECR checks passed. Temporary evidence: $testRoot"
