param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,
    [string]$ExpectedPath = ""
)

$ErrorActionPreference = "Stop"

function Convert-ToSortedObject {
    param($InputObject)

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $ordered = [ordered]@{}
        foreach ($name in ($InputObject.PSObject.Properties.Name | Sort-Object)) {
            $ordered[$name] = Convert-ToSortedObject $InputObject.$name
        }
        return [pscustomobject]$ordered
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($name in ($InputObject.Keys | Sort-Object)) {
            $ordered[$name] = Convert-ToSortedObject $InputObject[$name]
        }
        return [pscustomobject]$ordered
    }

    if ($InputObject -is [string]) {
        return ($InputObject -replace "`r`n", "`n")
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += ,(Convert-ToSortedObject $item)
        }
        return $items
    }

    return $InputObject
}

$ProjectRoot = Split-Path -Parent $PSScriptRoot

if (Test-Path $InputPath -PathType Container) {
    $scenarioPath = (Resolve-Path $InputPath).Path
    $InputPath = Join-Path $scenarioPath "input.json"

    if (-not $ExpectedPath) {
        $ExpectedPath = Join-Path $scenarioPath "expected.json"
    }
}

if (-not (Test-Path $InputPath)) {
    Write-Error "Input file not found: $InputPath"
}

$payload = Get-Content $InputPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($payload.PSObject.Properties.Name -contains "cwd") {
    $payload.cwd = $ProjectRoot
} else {
    Add-Member -InputObject $payload -NotePropertyName "cwd" -NotePropertyValue $ProjectRoot
}

$hookEvent = if ($payload.hook_event_name) { $payload.hook_event_name } elseif ($payload.hookEventName) { $payload.hookEventName } else { $null }
$hookScriptMap = @{
    "SessionStart" = ".github\hooks\scripts\01-session-start.ps1"
    "UserPromptSubmit" = ".github\hooks\scripts\02-user-prompt-submit.ps1"
    "PreToolUse" = ".github\hooks\scripts\03-pre-tool-use.ps1"
    "PostToolUse" = ".github\hooks\scripts\04-post-tool-use.ps1"
    "PreCompact" = ".github\hooks\scripts\05-pre-compact.ps1"
    "SubagentStart" = ".github\hooks\scripts\06-subagent-start.ps1"
}

if (-not $hookEvent -or -not $hookScriptMap.ContainsKey($hookEvent)) {
    Write-Error "Unsupported hook event in payload: $hookEvent"
}

$HookScript = Join-Path $ProjectRoot $hookScriptMap[$hookEvent]

if (-not (Test-Path $HookScript)) {
    Write-Error "Hook script not found: $HookScript"
}

$payloadJson = $payload | ConvertTo-Json -Depth 20 -Compress
$shellCommand = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $shellCommand) {
    $shellCommand = Get-Command powershell -ErrorAction Stop
}

$output = $payloadJson | & $shellCommand.Source -NoProfile -ExecutionPolicy Bypass -File $HookScript

if ([string]::IsNullOrWhiteSpace($output)) {
    Write-Error "Hook returned no output."
}

$actualObject = $output | ConvertFrom-Json
$actualPretty = $actualObject | ConvertTo-Json -Depth 20
Write-Host $actualPretty

if ($ExpectedPath) {
    if (-not (Test-Path $ExpectedPath)) {
        Write-Error "Expected file not found: $ExpectedPath"
    }

    $expectedObject = Get-Content $ExpectedPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $actualNormalized = (Convert-ToSortedObject $actualObject) | ConvertTo-Json -Depth 20 -Compress
    $expectedNormalized = (Convert-ToSortedObject $expectedObject) | ConvertTo-Json -Depth 20 -Compress

    if ($actualNormalized -ne $expectedNormalized) {
        Write-Error "Actual output did not match expected output."
    }

    Write-Host "Expected output matched."
}