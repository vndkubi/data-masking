#Requires -Version 7.0

param(
    [string]$CopilotHome = (Join-Path $HOME '.copilot')
)

$ErrorActionPreference = 'Stop'

$bundleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$hooksDir = Join-Path $CopilotHome 'hooks'
$scriptsDir = Join-Path $hooksDir 'scripts'
$logsDir = Join-Path $CopilotHome 'logs'

$filesToCopy = @(
    @{
        Source = Join-Path $bundleRoot 'masking-config.json'
        Target = Join-Path $CopilotHome 'masking-config.json'
    },
    @{
        Source = Join-Path $bundleRoot 'hooks\sensitive-data-mask.json'
        Target = Join-Path $hooksDir 'sensitive-data-mask.json'
    },
    @{
        Source = Join-Path $bundleRoot 'hooks\scripts\mask-sensitive-data.ps1'
        Target = Join-Path $scriptsDir 'mask-sensitive-data.ps1'
    }
)

foreach ($directory in @($CopilotHome, $hooksDir, $scriptsDir, $logsDir)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}

foreach ($file in $filesToCopy) {
    if (-not (Test-Path $file.Source -PathType Leaf)) {
        throw "Missing bundle file: $($file.Source)"
    }

    Copy-Item -Path $file.Source -Destination $file.Target -Force
}

Write-Host "Installed Copilot CLI bundle to $CopilotHome" -ForegroundColor Green
Write-Host "Config: $(Join-Path $CopilotHome 'masking-config.json')"
Write-Host "Hooks:  $(Join-Path $CopilotHome 'hooks')"