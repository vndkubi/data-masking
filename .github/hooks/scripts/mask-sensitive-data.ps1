#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

$targetScript = Join-Path $PSScriptRoot '..\..\..\cli\hooks\scripts\mask-sensitive-data.ps1'
$targetScript = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($targetScript)

if (-not (Test-Path $targetScript -PathType Leaf)) {
    [Console]::Out.WriteLine((@{
        continue      = $false
        stopReason    = 'Repo-local Copilot masking launcher could not find cli/hooks/scripts/mask-sensitive-data.ps1.'
        systemMessage = 'Repo-local Copilot masking launcher could not find cli/hooks/scripts/mask-sensitive-data.ps1.'
    } | ConvertTo-Json -Compress))
    exit 0
}

& $targetScript
exit $LASTEXITCODE
