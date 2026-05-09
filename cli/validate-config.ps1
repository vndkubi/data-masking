#Requires -Version 5.1

param(
    [string]$ConfigPath = '',
    [switch]$Strict,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path (Join-Path $scriptDir 'lib') 'mask-data-tools.ps1')

try {
    $resolvedConfigPath = Resolve-DefaultMaskDataConfigPath -ConfigPath $ConfigPath -WorkspaceRoot (Split-Path -Parent $scriptDir)
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}

$result = Test-MaskDataConfig -ConfigPath $resolvedConfigPath

if (-not $Quiet) {
    Write-Host "Config : $($result.ConfigPath)"
    Write-Host "Patterns: $($result.TotalPatterns) total, $($result.ActivePatterns) enabled"
}

foreach ($warning in $result.Warnings) {
    if (-not $Quiet) {
        Write-Warning $warning
    }
}

if ($result.Errors.Count -gt 0) {
    foreach ($errorText in $result.Errors) {
        [Console]::Error.WriteLine($errorText)
    }
    exit 1
}

if ($Strict -and $result.Warnings.Count -gt 0) {
    if (-not $Quiet) {
        [Console]::Error.WriteLine("Validation produced warnings and -Strict is enabled.")
    }
    exit 2
}

if (-not $Quiet) {
    Write-Host "Validation passed." -ForegroundColor Green
}

exit 0
