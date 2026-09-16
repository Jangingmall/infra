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

# Preserve relative module source paths in the isolated test tree.
$moduleRoot = Join-Path $testRoot 'terraform/modules/ecr'
New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null
Get-ChildItem -LiteralPath (Join-Path $repoRoot 'terraform/modules/ecr') -Filter '*.tf' |
    Copy-Item -Destination $moduleRoot
Copy-Item -LiteralPath (Join-Path $repoRoot 'tests/ecr/inputs.tftest.hcl') -Destination $moduleRoot

$checkRoots = @($moduleRoot)
foreach ($environment in @('prod', 'staging')) {
    $isolatedRoot = Join-Path $testRoot "terraform/environments/$environment"
    New-Item -ItemType Directory -Path $isolatedRoot -Force | Out-Null
    # Only ECR files and test provider requirements; no real backend/provider.
    Get-ChildItem -LiteralPath (Join-Path $repoRoot "terraform/environments/$environment") -Filter 'ecr*.tf' |
        Copy-Item -Destination $isolatedRoot
    if ($environment -eq 'prod') {
        # B-plan prod: copy only shared env/ECR blocks, not network outputs or resources.
        $sharedFiles = @(
            @{ Name = 'variables.tf'; Pattern = '(?ms)^variable "(?:env|ecr_[^"]+)" \{.*?^\}'; Count = 7 },
            @{ Name = 'outputs.tf'; Pattern = '(?ms)^output "ecr_[^"]+" \{.*?^\}'; Count = 3 }
        )
        foreach ($sharedFile in $sharedFiles) {
            $sourceFile = Join-Path $repoRoot "terraform/environments/$environment/$($sharedFile.Name)"
            $blocks = [regex]::Matches([System.IO.File]::ReadAllText($sourceFile), $sharedFile.Pattern)
            if ($blocks.Count -ne $sharedFile.Count) {
                throw "Unexpected env/ECR block count in $sourceFile : $($blocks.Count)"
            }
            $content = ($blocks | ForEach-Object { $_.Value }) -join "`n`n"
            [System.IO.File]::WriteAllText((Join-Path $isolatedRoot $sharedFile.Name), "$content`n", [System.Text.UTF8Encoding]::new($false))
        }
    }
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tests/ecr/versions.tf') -Destination $isolatedRoot
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tests/ecr/environment.tftest.hcl') -Destination $isolatedRoot
    $checkRoots += $isolatedRoot
}

foreach ($isolatedRoot in $checkRoots) {
    $initArgs = @('init', '-backend=false', '-input=false', '-no-color')
    if ($PluginDir) { $initArgs += "-plugin-dir=$PluginDir" }
    Invoke-TerraformCheck -Directory $isolatedRoot -Arguments $initArgs
    Invoke-TerraformCheck -Directory $isolatedRoot -Arguments @('fmt', '-check')
    Invoke-TerraformCheck -Directory $isolatedRoot -Arguments @('validate', '-no-color')
    Invoke-TerraformCheck -Directory $isolatedRoot -Arguments @('test', '-no-color')
}
Write-Output "ECR module and both environment checks passed. Temporary evidence: $testRoot"
