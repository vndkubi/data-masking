#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

$script:PolicyContext = @"
SECURITY POLICY ACTIVE - SENSITIVE DATA MASKING:
Sensitive data in this session has been automatically masked with [MASKED-*] placeholders.

RULES:
1. Always use the masked placeholder when referencing sensitive values.
2. When sending data to any tool or external service, use only the masked version.
3. Never attempt to recover or reconstruct original sensitive values.
4. Treat purely numeric filenames with 9-16 digits as [MASKED-FILENAME].
"@

$script:LogFile = $null

# Keep one small log file under ~/.copilot so the hook can skip quietly but still explain why.
function Initialize-Log {
    param([string]$ScriptDir)

    $copilotHome = Split-Path -Parent (Split-Path -Parent $ScriptDir)
    $logDir = Join-Path $copilotHome 'logs'

    try {
        [System.IO.Directory]::CreateDirectory($logDir) | Out-Null
        $script:LogFile = Join-Path $logDir 'mask-sensitive-data.log'
    } catch {
        $script:LogFile = $null
    }
}

function Write-Log {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($script:LogFile)) {
        return
    }

    $timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

    try {
        Add-Content -Path $script:LogFile -Value "[$timestamp] $Message" -Encoding UTF8
    } catch {
    }
}

function Write-HookOutput {
    param([hashtable]$Payload)

    [Console]::Out.WriteLine(($Payload | ConvertTo-Json -Depth 20 -Compress))
}

function Write-ContextOutput {
    param(
        [string]$HookEvent,
        [string]$Context
    )

    Write-HookOutput @{
        additionalContext  = $Context
        hookSpecificOutput = @{
            hookEventName     = $HookEvent
            additionalContext = $Context
        }
    }
}

function Write-DecisionOutput {
    param(
        [string]$HookEvent,
        [string]$Decision,
        [string]$Reason,
        $ModifiedArgs = $null
    )

    $hookSpecific = @{
        hookEventName             = $HookEvent
        permissionDecision        = $Decision
        permissionDecisionReason  = $Reason
    }

    $payload = @{
        permissionDecision        = $Decision
        permissionDecisionReason  = $Reason
        hookSpecificOutput        = $hookSpecific
    }

    if ($null -ne $ModifiedArgs) {
        $payload['modifiedArgs'] = $ModifiedArgs
        $hookSpecific['updatedInput'] = $ModifiedArgs
    }

    Write-HookOutput $payload
}

function Get-MapValue {
    param(
        [System.Collections.IDictionary]$Map,
        [string[]]$Keys,
        $Default = $null
    )

    foreach ($key in $Keys) {
        if ($Map.Contains($key) -and $null -ne $Map[$key]) {
            return $Map[$key]
        }
    }

    return $Default
}

function Copy-Hashtable {
    param([System.Collections.IDictionary]$Map)

    $copy = @{}
    if ($null -eq $Map) {
        return $copy
    }

    foreach ($key in $Map.Keys) {
        $copy[$key] = $Map[$key]
    }

    return $copy
}

# Windows PowerShell 5.1 lacks ConvertFrom-Json -AsHashtable, so normalize parsed
# JSON into plain hashtables before the hook logic reads it.
function ConvertTo-PlainHashtable {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $map = @{}
        foreach ($key in $Value.Keys) {
            $map[$key] = ConvertTo-PlainHashtable -Value $Value[$key]
        }
        return $map
    }

    if ($Value -is [pscustomobject]) {
        $map = @{}
        foreach ($property in $Value.PSObject.Properties) {
            $map[$property.Name] = ConvertTo-PlainHashtable -Value $property.Value
        }
        return $map
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = New-Object System.Collections.ArrayList
        foreach ($item in $Value) {
            [void]$items.Add((ConvertTo-PlainHashtable -Value $item))
        }
        return ,@($items.ToArray())
    }

    return $Value
}

# Config must be strict JSON. Disabled rules should use "enabled": false instead
# of comments so the same file parses in PowerShell 5.1, pwsh, jq, and editors.
function Read-ConfigFile {
    param([string]$Path)

    $content = Get-Content -Path $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "Config file '$Path' is empty."
    }

    return ConvertTo-PlainHashtable -Value ($content | ConvertFrom-Json)
}

# Pick the first existing config file in priority order. If it cannot be read, log and skip.
function Resolve-Config {
    param(
        [string]$WorkspaceRoot,
        [string]$ScriptDir,
        [string]$HookEvent
    )

    $copilotHome = Split-Path -Parent (Split-Path -Parent $ScriptDir)
    $candidates = @()

    if ($env:MASK_DATA_CONFIG) {
        $candidates += $env:MASK_DATA_CONFIG
    }

    if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        $candidates += (Join-Path (Join-Path $WorkspaceRoot '.copilot') 'masking-config.json')
        $candidates += (Join-Path (Join-Path (Join-Path $WorkspaceRoot '.github') 'hooks') 'masking-config.json')
    }

    $candidates += (Join-Path $copilotHome 'masking-config.json')

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path $candidate -PathType Leaf)) {
            continue
        }

        try {
            $config = Read-ConfigFile -Path $candidate
        } catch {
            Write-Log "[$HookEvent] Skipped: failed to read masking config '$candidate'. $($_.Exception.Message)"
            return $null
        }

        $hasPatterns = $config.Contains('patterns') -and $null -ne $config['patterns'] -and @($config['patterns']).Count -gt 0
        $hasCustomPatterns = $config.Contains('customPatterns') -and $null -ne $config['customPatterns'] -and @($config['customPatterns']).Count -gt 0

        if (-not $hasPatterns -and -not $hasCustomPatterns) {
            Write-Log "[$HookEvent] Skipped: masking config '$candidate' has no patterns or customPatterns."
            return $null
        }

        return $config
    }

    Write-Log "[$HookEvent] Skipped: masking-config.json was not found in any supported location."
    return $null
}

function Convert-ToJsonText {
    param($Value)

    if ($null -eq $Value) {
        return '{}'
    }

    if ($Value -is [string]) {
        return $Value
    }

    return ($Value | ConvertTo-Json -Depth 20 -Compress)
}

function Convert-ToHashtable {
    param($Value)

    if ($null -eq $Value) {
        return @{}
    }

    if ($Value -is [System.Collections.IDictionary]) {
        return (Copy-Hashtable -Map $Value)
    }

    try {
        return ConvertTo-PlainHashtable -Value (($Value | ConvertTo-Json -Depth 20 -Compress) | ConvertFrom-Json)
    } catch {
        return @{}
    }
}

function Get-EnabledPatternsFromGroup {
    param(
        [System.Collections.IDictionary]$Config,
        [string]$GroupName
    )

    $enabledPatterns = @()
    if (-not $Config.Contains($GroupName) -or $null -eq $Config[$GroupName]) {
        return $enabledPatterns
    }

    foreach ($pattern in @($Config[$GroupName])) {
        if ($pattern -isnot [System.Collections.IDictionary]) {
            continue
        }

        if ($pattern.Contains('enabled') -and $false -eq [bool]$pattern['enabled']) {
            continue
        }

        if (-not $pattern.Contains('regex') -or [string]::IsNullOrWhiteSpace([string]$pattern['regex'])) {
            continue
        }

        $enabledPatterns += $pattern
    }

    return $enabledPatterns
}

function Get-ActivePatterns {
    param([System.Collections.IDictionary]$Config)

    $allPatterns = @()
    $allPatterns += @(Get-EnabledPatternsFromGroup -Config $Config -GroupName 'patterns')
    $allPatterns += @(Get-EnabledPatternsFromGroup -Config $Config -GroupName 'customPatterns')

    return $allPatterns
}

# Two tiny helpers keep the decision code readable: one checks, one rewrites.
function Test-ContainsSensitive {
    param(
        [string]$Text,
        [System.Collections.IEnumerable]$Patterns
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    foreach ($pattern in $Patterns) {
        try {
            if ([regex]::IsMatch($Text, [string]$pattern['regex'])) {
                return $true
            }
        } catch {
        }
    }

    return $false
}

function Invoke-MaskText {
    param(
        [string]$Text,
        [System.Collections.IEnumerable]$Patterns
    )

    $result = $Text

    foreach ($pattern in $Patterns) {
        $replacement = if ($pattern.Contains('replacement')) {
            [string]$pattern['replacement']
        } elseif ($pattern.Contains('name')) {
            [string]$pattern['name']
        } else {
            $null
        }

        if ([string]::IsNullOrWhiteSpace($replacement)) {
            continue
        }

        try {
            $result = [regex]::Replace($result, [string]$pattern['regex'], $replacement)
        } catch {
        }
    }

    return $result
}

function Get-ToolPath {
    param([System.Collections.IDictionary]$ToolInput)

    foreach ($key in @('filePath', 'file_path', 'path')) {
        if ($ToolInput.Contains($key) -and -not [string]::IsNullOrWhiteSpace([string]$ToolInput[$key])) {
            return [string]$ToolInput[$key]
        }
    }

    return $null
}

function Update-ToolPath {
    param(
        [System.Collections.IDictionary]$ToolInput,
        [string]$NewPath
    )

    $updated = Copy-Hashtable -Map $ToolInput

    foreach ($key in @('path', 'filePath', 'file_path')) {
        if ($updated.Contains($key)) {
            $updated[$key] = $NewPath
            return $updated
        }
    }

    $updated['path'] = $NewPath
    return $updated
}

function Resolve-ToolPath {
    param(
        [string]$ToolPath,
        [string]$WorkspaceRoot
    )

    if ([string]::IsNullOrWhiteSpace($ToolPath)) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($ToolPath)) {
        return $ToolPath
    }

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        return $ToolPath
    }

    return (Join-Path $WorkspaceRoot $ToolPath)
}

function Get-MaskedTempPath {
    param([string]$SourcePath)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($SourcePath))
    } finally {
        $sha256.Dispose()
    }
    $hash = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
    $extension = [System.IO.Path]::GetExtension($SourcePath)

    if ([string]::IsNullOrWhiteSpace($extension)) {
        $extension = '.txt'
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'copilot-mask-cache'
    [System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null

    return (Join-Path $tempRoot ("masked-$hash$extension"))
}

function Write-Utf8File {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

$scriptPath = $MyInvocation.MyCommand.Path
$scriptDir = Split-Path -Parent $scriptPath
Initialize-Log -ScriptDir $scriptDir

# Parse stdin first. If the hook payload is broken there is nothing safe to do.
try {
    $rawInput = [Console]::In.ReadToEnd()
} catch {
    Write-Log '[unknown] Skipped: failed to read hook stdin.'
    exit 0
}

if ([string]::IsNullOrWhiteSpace($rawInput)) {
    Write-Log '[unknown] Skipped: hook stdin was empty.'
    exit 0
}

try {
    $hookData = ConvertTo-PlainHashtable -Value ($rawInput | ConvertFrom-Json)
} catch {
    Write-Log "[unknown] Skipped: hook payload was not valid JSON. $($_.Exception.Message)"
    exit 0
}

$hookEvent = [string](Get-MapValue -Map $hookData -Keys @('hook_event_name', 'hookEventName', 'eventName', 'event'))
if ([string]::IsNullOrWhiteSpace($hookEvent)) {
    Write-Log '[unknown] Skipped: hook event name was missing.'
    exit 0
}

$workspaceRoot = [string](Get-MapValue -Map $hookData -Keys @('cwd') -Default '.')
$config = Resolve-Config -WorkspaceRoot $workspaceRoot -ScriptDir $scriptDir -HookEvent $hookEvent
if ($null -eq $config) {
    exit 0
}

$patterns = Get-ActivePatterns -Config $config
if ($patterns.Count -eq 0) {
    Write-Log "[$hookEvent] Skipped: config has no enabled patterns."
    exit 0
}

$externalToolsRegex = if ($config.Contains('externalToolsRegex')) { [string]$config['externalToolsRegex'] } else { '^(search_web|fetch_webpage|mcp_.*|github_repo)$' }
$sensitiveFilenameRegex = if ($config.Contains('sensitiveFilenameRegex')) { [string]$config['sensitiveFilenameRegex'] } else { '(^|[\\/])\d{9,16}(\.[^\\/]+)?$' }

switch ($hookEvent) {
    'SessionStart' {
        Write-ContextOutput -HookEvent $hookEvent -Context $script:PolicyContext
        exit 0
    }

    'PreCompact' {
        Write-ContextOutput -HookEvent $hookEvent -Context '[SECURITY] Sensitive-data masking is active. Keep only masked placeholders in compacted context.'
        exit 0
    }

    'SubagentStart' {
        Write-ContextOutput -HookEvent $hookEvent -Context 'SECURITY POLICY (inherited): sensitive-data masking is active. Use only [MASKED-*] placeholders and never reconstruct originals.'
        exit 0
    }

    # All tool decisions live in one branch so the hook flow is easy to inspect.
    'PreToolUse' {
        $toolName = [string](Get-MapValue -Map $hookData -Keys @('tool_name', 'toolName') -Default 'unknown')
        $toolInputValue = Get-MapValue -Map $hookData -Keys @('tool_input', 'toolInput', 'input', 'toolArgs') -Default @{}
        $toolInputMap = Convert-ToHashtable -Value $toolInputValue
        $toolInputJson = Convert-ToJsonText -Value $toolInputValue

        if ([string]::IsNullOrWhiteSpace($toolInputJson) -or $toolInputJson -eq '{}' -or $toolInputJson -eq 'null') {
            exit 0
        }

        if ([regex]::IsMatch($toolName, $externalToolsRegex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) -and (Test-ContainsSensitive -Text $toolInputJson -Patterns $patterns)) {
            $maskedExternalInputJson = Invoke-MaskText -Text $toolInputJson -Patterns $patterns
            $modifiedExternalArgs = try {
                ConvertTo-PlainHashtable -Value ($maskedExternalInputJson | ConvertFrom-Json)
            } catch {
                $toolInputMap
            }

            Write-DecisionOutput -HookEvent $hookEvent -Decision 'ask' -Reason "Sensitive data detected in input to '$toolName'. The tool arguments were masked; confirm before sending them to an external service." -ModifiedArgs $modifiedExternalArgs
            exit 0
        }

        $toolPath = Get-ToolPath -ToolInput $toolInputMap
        if (-not [string]::IsNullOrWhiteSpace($toolPath) -and [regex]::IsMatch($toolPath, $sensitiveFilenameRegex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            Write-DecisionOutput -HookEvent $hookEvent -Decision 'deny' -Reason 'BLOCKED by security policy: the file path looks like a sensitive numeric filename. Use [MASKED-FILENAME] and rename the file first.'
            exit 0
        }

        if ($toolName -in @('view', 'read_file', 'readFile')) {
            $resolvedPath = Resolve-ToolPath -ToolPath $toolPath -WorkspaceRoot $workspaceRoot

            if (-not [string]::IsNullOrWhiteSpace($resolvedPath) -and (Test-Path $resolvedPath -PathType Leaf)) {
                $fileContent = Get-Content -Path $resolvedPath -Raw -Encoding UTF8

                if (Test-ContainsSensitive -Text $fileContent -Patterns $patterns) {
                    $maskedContent = Invoke-MaskText -Text $fileContent -Patterns $patterns

                    if ($toolName -eq 'view') {
                        $maskedPath = Get-MaskedTempPath -SourcePath $resolvedPath
                        Write-Utf8File -Path $maskedPath -Content $maskedContent
                        $modifiedPathArgs = Update-ToolPath -ToolInput $toolInputMap -NewPath $maskedPath

                        Write-DecisionOutput -HookEvent $hookEvent -Decision 'allow' -Reason 'Sensitive data was detected in file content. The read was redirected to a masked temporary copy.' -ModifiedArgs $modifiedPathArgs
                        exit 0
                    }

                    Write-DecisionOutput -HookEvent $hookEvent -Decision 'deny' -Reason "SECURITY: file contains sensitive data. Use this masked version only:`n$maskedContent"
                    exit 0
                }
            }
        }

        $maskedInputJson = Invoke-MaskText -Text $toolInputJson -Patterns $patterns
        if ($maskedInputJson -ne $toolInputJson) {
            $modifiedArgs = try {
                ConvertTo-PlainHashtable -Value ($maskedInputJson | ConvertFrom-Json)
            } catch {
                $toolInputMap
            }

            Write-DecisionOutput -HookEvent $hookEvent -Decision 'allow' -Reason 'Sensitive data was detected and masked before tool execution.' -ModifiedArgs $modifiedArgs
            exit 0
        }

        exit 0
    }

    default {
        exit 0
    }
}
