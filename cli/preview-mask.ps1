#Requires -Version 5.1

[CmdletBinding(DefaultParameterSetName = 'Text')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Text')]
    [string]$Text,

    [Parameter(Mandatory = $true, ParameterSetName = 'File')]
    [string]$FilePath,

    [string]$ConfigPath = '',
    [switch]$MaskedOnly
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path (Join-Path $scriptDir 'lib') 'mask-data-tools.ps1')

try {
    $resolvedConfigPath = Resolve-DefaultMaskDataConfigPath -ConfigPath $ConfigPath -WorkspaceRoot (Split-Path -Parent $scriptDir)
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

$validation = Test-MaskDataConfig -ConfigPath $resolvedConfigPath
if ($validation.Errors.Count -gt 0) {
    foreach ($errorText in $validation.Errors) {
        Write-Error $errorText
    }
    exit 1
}

foreach ($warning in $validation.Warnings) {
    Write-Warning $warning
}

$inputSource = 'text'
$originalText = $Text

if ($PSCmdlet.ParameterSetName -eq 'File') {
    $resolvedFilePath = Resolve-MaskDataFilePath -Path $FilePath
    $originalText = Get-Content -Path $resolvedFilePath -Raw -Encoding UTF8
    $inputSource = $resolvedFilePath
}

$patterns = Get-ActiveMaskPatterns -Config $validation.Config
$matchedPatterns = Get-MaskDataMatchedPatterns -Text $originalText -Patterns $patterns
$maskedText = Invoke-MaskDataText -Text $originalText -Patterns $patterns

if ($MaskedOnly) {
    [Console]::Out.WriteLine($maskedText)
    exit 0
}

Write-Host "Config         : $($validation.ConfigPath)"
Write-Host "Input Source   : $inputSource"
Write-Host "Active Patterns: $($patterns.Count)"
Write-Host "Matched        : $($matchedPatterns.Count)"

if ($matchedPatterns.Count -gt 0) {
    Write-Host "Matched Names  : $($matchedPatterns -join ', ')"
} else {
    Write-Host "Matched Names  : (none)"
}

Write-Host ""
Write-Host "--- Original ---" -ForegroundColor Cyan
[Console]::Out.WriteLine($originalText)
Write-Host ""
Write-Host "--- Masked ---" -ForegroundColor Green
[Console]::Out.WriteLine($maskedText)
