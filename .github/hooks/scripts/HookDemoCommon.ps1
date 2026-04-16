#Requires -Version 5.1

$script:DemoConfig = $null
$script:DemoConfigPath = $null
$script:DemoHookEvent = $null
$script:DemoCwd = "."
$script:DemoAuditFile = $null
$script:DemoExternalToolsRegex = '^(search_web|fetch_webpage|mcp_.*|github_repo|external_api_call)$'
$script:DemoFallbackSensitiveRegex = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'

$script:DemoScriptDir = Split-Path -Parent $PSCommandPath
$script:DemoHooksDir = Split-Path -Parent $script:DemoScriptDir
$script:DemoDiagDir = Join-Path $script:DemoHooksDir 'logs'
try { New-Item -ItemType Directory -Force -Path $script:DemoDiagDir | Out-Null } catch {}
$script:DemoDiagFile = Join-Path $script:DemoDiagDir 'hook-debug.log'

function Get-DemoTs {
    (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Write-DemoDiag {
    param([string]$Message)
    try { Add-Content -Path $script:DemoDiagFile -Value "[$(Get-DemoTs)] $Message" -Encoding UTF8 } catch {}
}

function Write-DemoAudit {
    param([string]$Event, [string]$Detail)
    if ($script:DemoAuditFile) {
        try { Add-Content -Path $script:DemoAuditFile -Value "[$(Get-DemoTs)] [$Event] $Detail" -Encoding UTF8 } catch {}
    }
}

function Read-DemoRawInput {
    try { [Console]::In.ReadToEnd() } catch { '' }
}

function Get-DemoHookEventName {
    param($HookData)
    if ($HookData.hook_event_name) { return $HookData.hook_event_name }
    if ($HookData.hookEventName) { return $HookData.hookEventName }
    return $null
}

function Initialize-DemoContext {
    param([string]$RawInput)

    try {
        $hookData = $RawInput | ConvertFrom-Json
    } catch {
        Write-DemoDiag "JSON parse failed: $_"
        return $null
    }

    $script:DemoHookEvent = Get-DemoHookEventName -HookData $hookData
    if (-not $script:DemoHookEvent) {
        Write-DemoDiag 'No hook event found in payload'
        return $null
    }

    $script:DemoCwd = if ($hookData.cwd) { $hookData.cwd } else { '.' }
    $configPath = Join-Path $script:DemoCwd '.github\hooks\masking-config.json'
    $script:DemoConfig = $null
    $script:DemoConfigPath = $null

    if (Test-Path $configPath) {
        try {
            $rawJson = (Get-Content $configPath -Raw -Encoding UTF8) -replace '(?m)^\s*//.*$', ''
            $script:DemoConfig = $rawJson | ConvertFrom-Json
            $script:DemoConfigPath = $configPath
            if ($script:DemoConfig.externalToolsRegex) {
                $script:DemoExternalToolsRegex = $script:DemoConfig.externalToolsRegex
            }
        } catch {
            Write-DemoDiag "Failed to load config: $_"
        }
    }

    $logDir = Join-Path $script:DemoCwd 'logs'
    try { New-Item -ItemType Directory -Force -Path $logDir | Out-Null } catch {}
    $script:DemoAuditFile = Join-Path $logDir 'copilot-mask-audit.log'
    Write-DemoDiag "Initialized support escalation demo for $($script:DemoHookEvent)"
    return $hookData
}

function Invoke-DemoMask {
    param([string]$Content)

    $result = $Content
    if (-not $script:DemoConfig) {
        return [regex]::Replace($result, $script:DemoFallbackSensitiveRegex, '[MASKED-EMAIL]')
    }

    if ($script:DemoConfig.patterns) {
        foreach ($pattern in $script:DemoConfig.patterns) {
            if ($null -ne $pattern.enabled -and $pattern.enabled -eq $false) { continue }
            if (-not $pattern.regex) { continue }
            if (-not $pattern.replacement) { continue }
            try { $result = [regex]::Replace($result, $pattern.regex, $pattern.replacement) } catch {}
        }
    }

    if ($script:DemoConfig.customPatterns) {
        foreach ($pattern in $script:DemoConfig.customPatterns) {
            if (-not $pattern.regex) { continue }
            $replacement = if ($pattern.replacement) { $pattern.replacement } else { $pattern.name }
            if (-not $replacement) { continue }
            try { $result = [regex]::Replace($result, $pattern.regex, $replacement) } catch {}
        }
    }

    return $result
}

function Test-DemoSensitive {
    param([string]$Content)

    if (-not $script:DemoConfig) {
        return [regex]::IsMatch($Content, $script:DemoFallbackSensitiveRegex)
    }

    if ($script:DemoConfig.patterns) {
        foreach ($pattern in $script:DemoConfig.patterns) {
            if ($null -ne $pattern.enabled -and $pattern.enabled -eq $false) { continue }
            if (-not $pattern.regex) { continue }
            try { if ([regex]::IsMatch($Content, $pattern.regex)) { return $true } } catch {}
        }
    }

    if ($script:DemoConfig.customPatterns) {
        foreach ($pattern in $script:DemoConfig.customPatterns) {
            if (-not $pattern.regex) { continue }
            try { if ([regex]::IsMatch($Content, $pattern.regex)) { return $true } } catch {}
        }
    }

    return $false
}

function Write-DemoJsonOutput {
    param([hashtable]$Object)
    [Console]::Out.WriteLine(($Object | ConvertTo-Json -Depth 20 -Compress))
}

function ConvertTo-DemoJsonString {
    param($Value)
    if ($Value -is [string]) { return $Value }
    return ($Value | ConvertTo-Json -Depth 20 -Compress)
}

function Get-DemoToolName {
    param($HookData)
    if ($HookData.tool_name) { return $HookData.tool_name }
    if ($HookData.toolName) { return $HookData.toolName }
    return 'unknown'
}

function Get-DemoToolInputObject {
    param($HookData)
    if ($null -ne $HookData.tool_input) { return $HookData.tool_input }
    if ($null -ne $HookData.toolInput) { return $HookData.toolInput }
    if ($null -ne $HookData.input) { return $HookData.input }
    if ($null -ne $HookData.toolArgs) { return $HookData.toolArgs }
    return $null
}

function Get-DemoToolResponseObject {
    param($HookData)
    if ($null -ne $HookData.tool_response) { return $HookData.tool_response }
    if ($null -ne $HookData.toolResponse) { return $HookData.toolResponse }
    if ($null -ne $HookData.output) { return $HookData.output }
    return $null
}