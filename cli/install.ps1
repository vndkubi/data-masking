#Requires -Version 5.1

param(
    [string]$CopilotHome = (Join-Path $HOME '.copilot'),
    [switch]$NoBackup,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

$bundleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path (Join-Path $bundleRoot 'lib') 'mask-data-tools.ps1')

function Resolve-FullPath {
    param([string]$Path)

    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Test-JsonFile {
    param([string]$Path)

    try {
        [void](Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        throw "Invalid JSON in '$Path'. $($_.Exception.Message)"
    }
}

function Copy-WithBackup {
    param(
        [string]$Source,
        [string]$Target,
        [switch]$NoBackup
    )

    if (-not (Test-Path $Source -PathType Leaf)) {
        throw "Missing bundle file: $Source"
    }

    $targetDir = Split-Path -Parent $Target
    if (-not (Test-Path $targetDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    }

    if ((Test-Path $Target -PathType Leaf) -and -not $NoBackup) {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item -Path $Target -Destination "$Target.bak-$timestamp" -Force
    }

    Copy-Item -Path $Source -Destination $Target -Force
}

function New-HookConfig {
    param([string]$ScriptPath)

    $bashScriptPath = $ScriptPath -replace '\\', '/'
    $powershellCommand = "powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $bashCommand = "pwsh -NoLogo -NoProfile -File `"$bashScriptPath`""

    $commandHook = {
        return @{
            type = 'command'
            bash = $bashCommand
            powershell = $powershellCommand
            timeoutSec = 15
        }
    }

    return [ordered]@{
        version = 1
        hooks = [ordered]@{
            SessionStart = @(& $commandHook)
            PreToolUse = @(& $commandHook)
            PreCompact = @(& $commandHook)
            SubagentStart = @(& $commandHook)
        }
    }
}

$copilotHomePath = Resolve-FullPath -Path $CopilotHome
$hooksDir = Join-Path $copilotHomePath 'hooks'
$scriptsDir = Join-Path $hooksDir 'scripts'
$logsDir = Join-Path $copilotHomePath 'logs'

$sourceConfig = Join-Path $bundleRoot 'masking-config.json'
$sourceScript = Join-Path (Join-Path (Join-Path $bundleRoot 'hooks') 'scripts') 'mask-sensitive-data.ps1'

$validation = Test-MaskDataConfig -ConfigPath $sourceConfig
foreach ($warning in $validation.Warnings) {
    Write-Warning $warning
}
if ($validation.Errors.Count -gt 0) {
    throw ($validation.Errors -join [Environment]::NewLine)
}

Test-JsonFile -Path $sourceConfig

if ($Check) {
    Write-Host "Validation passed for $($validation.ConfigPath)." -ForegroundColor Green
    Write-Host "Patterns: $($validation.TotalPatterns) total, $($validation.ActivePatterns) enabled"
    exit 0
}

foreach ($directory in @($copilotHomePath, $hooksDir, $scriptsDir, $logsDir)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}

$targetConfig = Join-Path $copilotHomePath 'masking-config.json'
$targetScript = Join-Path $scriptsDir 'mask-sensitive-data.ps1'
$targetHookConfig = Join-Path $hooksDir 'sensitive-data-mask.json'

Copy-WithBackup -Source $sourceConfig -Target $targetConfig -NoBackup:$NoBackup
Copy-WithBackup -Source $sourceScript -Target $targetScript -NoBackup:$NoBackup

$hookConfigJson = New-HookConfig -ScriptPath $targetScript | ConvertTo-Json -Depth 10
Write-Utf8NoBom -Path $targetHookConfig -Content ($hookConfigJson + [Environment]::NewLine)
Test-JsonFile -Path $targetHookConfig

$runningOnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if (-not $runningOnWindows -and -not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Write-Warning "pwsh was not found on PATH. Install PowerShell 7 on macOS/WSL before using these hooks."
}

Write-Host "Installed Copilot CLI masking bundle." -ForegroundColor Green
Write-Host "Home   : $copilotHomePath"
Write-Host "Config : $targetConfig"
Write-Host "Hooks  : $targetHookConfig"
Write-Host "Script : $targetScript"

if ($runningOnWindows) {
    Write-Host "Runtime: Windows PowerShell 5.1 via powershell.exe"
} else {
    Write-Host "Runtime: PowerShell 7 via pwsh"
}
