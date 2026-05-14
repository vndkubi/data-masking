#Requires -Version 5.1

param(
    [string]$CopilotHome = (Join-Path $HOME '.copilot'),
    [string]$WorkspaceRoot,
    [switch]$NoBackup,
    [switch]$NoWorkspaceGitignore,
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

function Add-GitignoreEntry {
    param(
        [string]$WorkspacePath,
        [string[]]$Entries
    )

    $gitignorePath = Join-Path $WorkspacePath '.gitignore'
    $existingLines = @()
    if (Test-Path $gitignorePath -PathType Leaf) {
        $existingLines = @(Get-Content -Path $gitignorePath -Encoding UTF8)
    }

    $newLines = New-Object System.Collections.ArrayList
    foreach ($line in $existingLines) {
        [void]$newLines.Add($line)
    }

    $missingEntries = @($Entries | Where-Object {
        $entry = $_.TrimStart('/')
        $isAlreadyCovered = $false
        foreach ($line in $existingLines) {
            $trimmedLine = $line.Trim()
            if ($trimmedLine -eq $_ -or $trimmedLine -eq $entry -or $trimmedLine -eq "**/$entry") {
                $isAlreadyCovered = $true
                break
            }
        }

        -not $isAlreadyCovered
    })
    if ($missingEntries.Count -eq 0) {
        return
    }

    if ($newLines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$newLines[$newLines.Count - 1])) {
        [void]$newLines.Add('')
    }
    [void]$newLines.Add('# Copilot masking local install')
    foreach ($entry in $missingEntries) {
        [void]$newLines.Add($entry)
    }

    Write-Utf8NoBom -Path $gitignorePath -Content ((@($newLines.ToArray()) -join [Environment]::NewLine) + [Environment]::NewLine)
}

function New-HookConfig {
    param(
        [string]$ScriptPath,
        [string]$CwdPath = ''
    )

    $bashScriptPath = $ScriptPath -replace '\\', '/'
    $powershellCommand = "powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $pwshCommand = "pwsh -NoLogo -NoProfile -File `"$bashScriptPath`""

    $commandHook = {
        $hook = @{
            type = 'command'
            bash = $pwshCommand
            powershell = $powershellCommand
            command = $pwshCommand
            timeoutSec = 15
            windows = $powershellCommand
            linux = $pwshCommand
            osx = $pwshCommand
            timeout = 15
        }

        if (-not [string]::IsNullOrWhiteSpace($CwdPath)) {
            $hook['cwd'] = $CwdPath
        }

        return $hook
    }

    $events = @(
        'SessionStart',
        'UserPromptSubmit',
        'PreToolUse',
        'PermissionRequest',
        'PostToolUse',
        'PostToolUseFailure',
        'PreCompact',
        'Stop',
        'SubagentStart',
        'SubagentStop',
        'SessionEnd',
        'ErrorOccurred',
        'Notification'
    )

    $hooks = [ordered]@{}
    foreach ($event in $events) {
        $hooks[$event] = @(& $commandHook)
    }

    return [ordered]@{
        version = 1
        disableAllHooks = $false
        hooks = $hooks
    }
}

$copilotHomePath = Resolve-FullPath -Path $CopilotHome
$workspaceRootPath = if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) { Resolve-FullPath -Path $WorkspaceRoot } else { $null }
if ($workspaceRootPath -and -not (Test-Path $workspaceRootPath -PathType Container)) {
    throw "WorkspaceRoot '$workspaceRootPath' does not exist or is not a directory."
}

$hooksDir = Join-Path $copilotHomePath 'hooks'
$scriptsDir = Join-Path $hooksDir 'scripts'
$logsDir = Join-Path $copilotHomePath 'logs'

$sourceConfig = Join-Path $bundleRoot 'masking-config.json'
$sourceScript = Join-Path (Join-Path (Join-Path $bundleRoot 'hooks') 'scripts') 'mask-sensitive-data.ps1'
$sourceCommandWrapper = Join-Path (Join-Path (Join-Path $bundleRoot 'hooks') 'scripts') 'mask-command-output.ps1'

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
$targetCommandWrapper = Join-Path $scriptsDir 'mask-command-output.ps1'
$targetHookConfig = Join-Path $hooksDir 'sensitive-data-mask.json'

Copy-WithBackup -Source $sourceConfig -Target $targetConfig -NoBackup:$NoBackup
Copy-WithBackup -Source $sourceScript -Target $targetScript -NoBackup:$NoBackup
Copy-WithBackup -Source $sourceCommandWrapper -Target $targetCommandWrapper -NoBackup:$NoBackup

if ([string]::IsNullOrWhiteSpace($workspaceRootPath)) {
    $hookConfigJson = New-HookConfig -ScriptPath $targetScript | ConvertTo-Json -Depth 10
    Write-Utf8NoBom -Path $targetHookConfig -Content ($hookConfigJson + [Environment]::NewLine)
    Test-JsonFile -Path $targetHookConfig
} else {
    $existingGlobalHookConfig = Test-Path $targetHookConfig -PathType Leaf
    $workspaceCopilotDir = Join-Path $workspaceRootPath '.copilot'
    $workspaceHooksDir = Join-Path $workspaceCopilotDir 'hooks'
    $workspaceMirrorDir = Join-Path $workspaceCopilotDir 'masked-data'
    foreach ($directory in @($workspaceCopilotDir, $workspaceHooksDir, $workspaceMirrorDir)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $workspaceConfig = Join-Path $workspaceCopilotDir 'masking-config.json'
    $workspaceHookConfig = Join-Path $workspaceHooksDir 'sensitive-data-mask.json'
    Copy-WithBackup -Source $sourceConfig -Target $workspaceConfig -NoBackup:$NoBackup

    $workspaceHookConfigJson = New-HookConfig -ScriptPath $targetScript -CwdPath $workspaceRootPath | ConvertTo-Json -Depth 10
    Write-Utf8NoBom -Path $workspaceHookConfig -Content ($workspaceHookConfigJson + [Environment]::NewLine)
    Test-JsonFile -Path $workspaceHookConfig

    if (-not $NoWorkspaceGitignore) {
        Add-GitignoreEntry -WorkspacePath $workspaceRootPath -Entries @(
            '.copilot/masked-data/',
            '.copilot/hooks/sensitive-data-mask.json',
            '.copilot/masking-config.json'
        )
    }
}

$runningOnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if (-not $runningOnWindows -and -not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Write-Warning "pwsh was not found on PATH. Install PowerShell 7 in the active Linux/macOS/WSL/devcontainer environment before using these hooks."
}

Write-Host "Installed Copilot CLI masking bundle." -ForegroundColor Green
Write-Host "Home   : $copilotHomePath"
Write-Host "Config : $targetConfig"
Write-Host "Script : $targetScript"
Write-Host "Wrapper: $targetCommandWrapper"

if ([string]::IsNullOrWhiteSpace($workspaceRootPath)) {
    Write-Host "Hooks  : $targetHookConfig"
    Write-Host "Workspace mirror: run with -WorkspaceRoot <repo> to install cwd-aware repo hooks for .copilot/masked-data."
} else {
    Write-Host "Workspace      : $workspaceRootPath"
    Write-Host "Workspace config: $workspaceConfig"
    Write-Host "Workspace hooks : $workspaceHookConfig"
    Write-Host "Masked mirror   : $workspaceMirrorDir"
    if ($NoWorkspaceGitignore) {
        Write-Warning "Workspace gitignore was not updated. Ensure .copilot/masked-data/ and generated local hook files are not committed."
    } else {
        Write-Host "Gitignore       : ensured local Copilot masking outputs are ignored"
    }
    if ($existingGlobalHookConfig) {
        Write-Warning "Existing global hook config still exists at $targetHookConfig. Avoid enabling both global and workspace hook configs for the same request, or the hook may run twice."
    }
}

if ($runningOnWindows) {
    Write-Host "Runtime: Windows PowerShell 5.1 via powershell.exe"
} else {
    Write-Host "Runtime: PowerShell 7 via pwsh"
}
