#Requires -Version 5.1

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('bash', 'powershell')]
    [string]$Shell,

    [Parameter(Mandatory = $true)]
    [string]$EncodedCommand,

    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

$targetScript = Join-Path $PSScriptRoot '..\..\..\cli\hooks\scripts\mask-command-output.ps1'
$targetScript = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($targetScript)

if (-not (Test-Path $targetScript -PathType Leaf)) {
    [Console]::Error.WriteLine('Repo-local Copilot masking launcher could not find cli/hooks/scripts/mask-command-output.ps1.')
    exit 1
}

& $targetScript -Shell $Shell -EncodedCommand $EncodedCommand -ConfigPath $ConfigPath
exit $LASTEXITCODE
