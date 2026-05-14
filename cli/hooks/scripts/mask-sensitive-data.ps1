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
5. Do not read raw secrets, exports, dumps, payment files, or customer data files.
6. Do not run shell commands that can upload data to external services.
"@

$script:LogFile = $null
$script:MaskDataConfigPath = $null

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

function Write-CommonStopOutput {
    param(
        [string]$Reason,
        [string]$SystemMessage
    )

    $payload = @{
        systemMessage = $SystemMessage
    }

    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        $payload['continue'] = $false
        $payload['stopReason'] = $Reason
    }

    Write-HookOutput $payload
}

function Write-PostToolUseContextOutput {
    param(
        [string]$SystemMessage,
        [string]$AdditionalContext,
        [switch]$Block,
        [string]$Reason
    )

    $payload = @{}

    if ($Block) {
        $payload['decision'] = 'block'
        $payload['reason'] = $Reason
        $payload['continue'] = $false
        $payload['stopReason'] = $Reason
    }

    if (-not [string]::IsNullOrWhiteSpace($SystemMessage)) {
        $payload['systemMessage'] = $SystemMessage
    }

    if (-not [string]::IsNullOrWhiteSpace($AdditionalContext)) {
        $payload['hookSpecificOutput'] = @{
            hookEventName = 'PostToolUse'
            additionalContext = $AdditionalContext
        }
    }

    Write-HookOutput $payload
}

function Write-StopContextOutput {
    param(
        [string]$HookEvent,
        [string]$SystemMessage,
        [string]$Reason,
        [switch]$Block
    )

    $payload = @{}

    if (-not [string]::IsNullOrWhiteSpace($SystemMessage)) {
        $payload['systemMessage'] = $SystemMessage
    }

    if ($Block) {
        $payload['hookSpecificOutput'] = @{
            hookEventName = $HookEvent
            decision = 'block'
            reason = $Reason
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($Reason)) {
        $payload['hookSpecificOutput'] = @{
            hookEventName = $HookEvent
            additionalContext = $Reason
        }
    }

    Write-HookOutput $payload
}

function Write-PermissionRequestAllow {
    param([string]$Message)

    $payload = @{
        behavior = 'allow'
    }

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $payload['message'] = $Message
    }

    Write-HookOutput $payload
}

function Write-PermissionRequestDecision {
    param(
        [string]$Behavior,
        [string]$Message,
        [switch]$Interrupt
    )

    $payload = @{
        behavior = $Behavior
    }

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $payload['message'] = $Message
    }

    if ($Interrupt) {
        $payload['interrupt'] = $true
    }

    Write-HookOutput $payload
}

function Get-PreviewText {
    param(
        [string]$Text,
        [int]$MaxLength = 1200
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }

    if ($Text.Length -le $MaxLength) {
        return $Text
    }

    return ($Text.Substring(0, $MaxLength) + "`n...[truncated]")
}

function Get-TranscriptPath {
    param([System.Collections.IDictionary]$HookData)

    return [string](Get-MapValue -Map $HookData -Keys @('transcript_path', 'transcriptPath'))
}

function Test-StopHookAlreadyActive {
    param([System.Collections.IDictionary]$HookData)

    $value = Get-MapValue -Map $HookData -Keys @('stop_hook_active', 'stopHookActive') -Default $false
    return [bool]$value
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

        $script:MaskDataConfigPath = $candidate
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
        $converted = ConvertTo-PlainHashtable -Value (($Value | ConvertTo-Json -Depth 20 -Compress) | ConvertFrom-Json)
        if ($converted -is [System.Collections.IDictionary]) {
            return $converted
        }
    } catch {
    }

    return @{}
}

function Normalize-HookEventName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    switch ($Name.ToLowerInvariant()) {
        'sessionstart' { return 'SessionStart' }
        'sessionend' { return 'SessionEnd' }
        'userpromptsubmitted' { return 'UserPromptSubmit' }
        'userpromptsubmit' { return 'UserPromptSubmit' }
        'pretooluse' { return 'PreToolUse' }
        'permissionrequest' { return 'PermissionRequest' }
        'posttooluse' { return 'PostToolUse' }
        'posttoolusefailure' { return 'PostToolUseFailure' }
        'precompact' { return 'PreCompact' }
        'agentstop' { return 'Stop' }
        'stop' { return 'Stop' }
        'subagentstart' { return 'SubagentStart' }
        'subagentstop' { return 'SubagentStop' }
        'erroroccurred' { return 'ErrorOccurred' }
        'notification' { return 'Notification' }
        default { return $Name }
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
function Get-NormalizedDigits {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    return ([regex]::Replace($Value, '\D', ''))
}

function Test-LuhnChecksum {
    param([string]$Value)

    $digits = Get-NormalizedDigits -Value $Value
    if ($digits.Length -lt 13 -or $digits.Length -gt 19) {
        return $false
    }

    if (($digits.ToCharArray() | Select-Object -Unique).Count -lt 2) {
        return $false
    }

    $sum = 0
    $doubleDigit = $false
    for ($i = $digits.Length - 1; $i -ge 0; $i--) {
        $n = [int]::Parse($digits[$i])
        if ($doubleDigit) {
            $n *= 2
            if ($n -gt 9) {
                $n -= 9
            }
        }
        $sum += $n
        $doubleDigit = -not $doubleDigit
    }

    return (($sum % 10) -eq 0)
}

function Test-PatternMatchValue {
    param(
        [System.Collections.IDictionary]$Pattern,
        [string]$Value
    )

    $validator = if ($Pattern.Contains('validator')) { [string]$Pattern['validator'] } else { '' }
    switch ($validator.ToLowerInvariant()) {
        'luhn' { return (Test-LuhnChecksum -Value $Value) }
        default { return $true }
    }
}

function Test-PatternMatchesText {
    param(
        [System.Collections.IDictionary]$Pattern,
        [string]$Text
    )

    $regex = [regex]::new([string]$Pattern['regex'])
    $matches = $regex.Matches($Text)
    foreach ($match in $matches) {
        if (Test-PatternMatchValue -Pattern $Pattern -Value $match.Value) {
            return $true
        }
    }

    return $false
}

function Invoke-PatternMaskText {
    param(
        [string]$Text,
        [System.Collections.IDictionary]$Pattern,
        [string]$Replacement
    )

    $validator = if ($Pattern.Contains('validator')) { [string]$Pattern['validator'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($validator)) {
        return [regex]::Replace($Text, [string]$Pattern['regex'], $Replacement)
    }

    $regex = [regex]::new([string]$Pattern['regex'])
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param([System.Text.RegularExpressions.Match]$Match)

        if (Test-PatternMatchValue -Pattern $Pattern -Value $Match.Value) {
            return $Replacement
        }

        return $Match.Value
    }

    return $regex.Replace($Text, $evaluator)
}

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
            if (Test-PatternMatchesText -Pattern $pattern -Text $Text) {
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
            $result = Invoke-PatternMaskText -Text $result -Pattern $pattern -Replacement $replacement
        } catch {
        }
    }

    return $result
}

function Invoke-MaskValue {
    param(
        $Value,
        [System.Collections.IEnumerable]$Patterns
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        return (Invoke-MaskText -Text $Value -Patterns $Patterns)
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $maskedMap = @{}
        foreach ($key in $Value.Keys) {
            $maskedMap[$key] = Invoke-MaskValue -Value $Value[$key] -Patterns $Patterns
        }
        return $maskedMap
    }

    if ($Value -is [pscustomobject]) {
        $maskedObject = @{}
        foreach ($property in $Value.PSObject.Properties) {
            $maskedObject[$property.Name] = Invoke-MaskValue -Value $property.Value -Patterns $Patterns
        }
        return $maskedObject
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $maskedItems = New-Object System.Collections.ArrayList
        foreach ($item in $Value) {
            [void]$maskedItems.Add((Invoke-MaskValue -Value $item -Patterns $Patterns))
        }
        return ,@($maskedItems.ToArray())
    }

    return $Value
}

function Get-MatchedPatterns {
    param(
        [string]$Text,
        [System.Collections.IEnumerable]$Patterns
    )

    $matchedPatterns = @()
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $matchedPatterns
    }

    foreach ($pattern in $Patterns) {
        try {
            if (Test-PatternMatchesText -Pattern $pattern -Text $Text) {
                $matchedPatterns += $pattern
            }
        } catch {
        }
    }

    return $matchedPatterns
}

function Get-PatternDisplayNames {
    param([System.Collections.IEnumerable]$Patterns)

    $names = @()
    foreach ($pattern in $Patterns) {
        if ($pattern -isnot [System.Collections.IDictionary]) {
            continue
        }

        if ($pattern.Contains('name') -and -not [string]::IsNullOrWhiteSpace([string]$pattern['name'])) {
            $names += [string]$pattern['name']
        }
    }

    return @($names | Select-Object -Unique)
}

function Get-EventActionPriority {
    param(
        [string]$HookEvent,
        [string]$Action
    )

    switch ($HookEvent) {
        'UserPromptSubmit' {
            switch ($Action) {
                'mask' { return 0 }
                'stop' { return 1 }
            }
        }
        'PreToolUse' {
            switch ($Action) {
                'mask' { return 0 }
                'deny' { return 1 }
            }
        }
        'PermissionRequest' {
            switch ($Action) {
                'mask' { return 0 }
                'deny' { return 1 }
                'interrupt' { return 2 }
            }
        }
        'PostToolUse' {
            switch ($Action) {
                'mask' { return 0 }
                'block' { return 1 }
            }
        }
        'Stop' {
            switch ($Action) {
                'mask' { return 0 }
                'block' { return 1 }
            }
        }
        'SubagentStop' {
            switch ($Action) {
                'mask' { return 0 }
                'block' { return 1 }
            }
        }
    }

    return -1
}

function Resolve-EnforcementAction {
    param(
        [string]$HookEvent,
        [System.Collections.IEnumerable]$MatchedPatterns
    )

    $selectedAction = 'mask'
    $selectedPriority = 0

    foreach ($pattern in $MatchedPatterns) {
        if ($pattern -isnot [System.Collections.IDictionary] -or -not $pattern.Contains('enforcement') -or $null -eq $pattern['enforcement']) {
            continue
        }

        $enforcement = $pattern['enforcement']
        if ($enforcement -isnot [System.Collections.IDictionary] -or -not $enforcement.Contains($HookEvent)) {
            continue
        }

        $candidateAction = [string]$enforcement[$HookEvent]
        $candidatePriority = Get-EventActionPriority -HookEvent $HookEvent -Action $candidateAction
        if ($candidatePriority -gt $selectedPriority) {
            $selectedAction = $candidateAction
            $selectedPriority = $candidatePriority
        }
    }

    return $selectedAction
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

function Get-ToolCommand {
    param([System.Collections.IDictionary]$ToolInput)

    foreach ($key in @('command', 'cmd', 'script')) {
        if ($ToolInput.Contains($key) -and -not [string]::IsNullOrWhiteSpace([string]$ToolInput[$key])) {
            return [pscustomobject]@{
                Key = $key
                Value = [string]$ToolInput[$key]
            }
        }
    }

    return $null
}

function Update-ToolCommand {
    param(
        [System.Collections.IDictionary]$ToolInput,
        [string]$CommandKey,
        [string]$NewCommand
    )

    $updated = Copy-Hashtable -Map $ToolInput

    if ([string]::IsNullOrWhiteSpace($CommandKey)) {
        $updated['command'] = $NewCommand
        return $updated
    }

    $updated[$CommandKey] = $NewCommand
    return $updated
}

function Test-ShellTool {
    param([string]$ToolName)

    return ($ToolName -in @('bash', 'powershell', 'run_in_terminal', 'runInTerminal', 'terminal'))
}

function Test-ConfiguredRegexMatch {
    param(
        [string]$Text,
        [string]$Regex,
        [string]$Validator = ''
    )

    if ([string]::IsNullOrWhiteSpace($Text) -or [string]::IsNullOrWhiteSpace($Regex)) {
        return $false
    }

    try {
        $regexObj = [regex]::new($Regex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ([string]::IsNullOrWhiteSpace($Validator)) {
            return $regexObj.IsMatch($Text)
        }

        foreach ($match in $regexObj.Matches($Text)) {
            switch ($Validator.ToLowerInvariant()) {
                'luhn' {
                    if (Test-LuhnChecksum -Value $match.Value) {
                        return $true
                    }
                }
                default {
                    return $true
                }
            }
        }

        return $false
    } catch {
        return $false
    }
}

function ConvertTo-Base64Utf8 {
    param([string]$Text)

    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
}

function ConvertTo-ForwardSlashPath {
    param([string]$Path)

    return ($Path -replace '\\', '/')
}

function Quote-BashArgument {
    param([string]$Value)

    if ($null -eq $Value) {
        return "''"
    }

    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Quote-PowerShellArgument {
    param([string]$Value)

    if ($null -eq $Value) {
        return "''"
    }

    return "'" + ($Value -replace "'", "''") + "'"
}

function Get-CommandOutputWrapperPath {
    param([string]$ScriptDir)

    return (Join-Path $ScriptDir 'mask-command-output.ps1')
}

function New-MaskedShellCommand {
    param(
        [string]$ToolName,
        [string]$Command,
        [string]$WrapperPath,
        [string]$ConfigPath
    )

    $encodedCommand = ConvertTo-Base64Utf8 -Text $Command

    if ($ToolName -eq 'bash') {
        $wrapperPathForShell = ConvertTo-ForwardSlashPath -Path $WrapperPath
        $configPathForShell = ConvertTo-ForwardSlashPath -Path $ConfigPath

        return @(
            'pwsh',
            '-NoLogo',
            '-NoProfile',
            '-File',
            (Quote-BashArgument -Value $wrapperPathForShell),
            '-Shell',
            'bash',
            '-EncodedCommand',
            (Quote-BashArgument -Value $encodedCommand),
            '-ConfigPath',
            (Quote-BashArgument -Value $configPathForShell)
        ) -join ' '
    }

    return @(
        'powershell',
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Quote-PowerShellArgument -Value $WrapperPath),
        '-Shell',
        'powershell',
        '-EncodedCommand',
        (Quote-PowerShellArgument -Value $encodedCommand),
        '-ConfigPath',
        (Quote-PowerShellArgument -Value $ConfigPath)
    ) -join ' '
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

function Get-ToolReadContent {
    param(
        [string]$ToolName,
        [System.Collections.IDictionary]$ToolInput,
        [string]$WorkspaceRoot
    )

    if ($toolName -notin @('view', 'read_file', 'readFile')) {
        return $null
    }

    $toolPath = Get-ToolPath -ToolInput $ToolInput
    $resolvedPath = Resolve-ToolPath -ToolPath $toolPath -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace($resolvedPath) -or -not (Test-Path $resolvedPath -PathType Leaf)) {
        return $null
    }

    try {
        if ($ToolName -eq 'view') {
            return (Get-Content -Path $resolvedPath -Raw -Encoding UTF8)
        }

        $lines = @(Get-Content -Path $resolvedPath -Encoding UTF8)
        if ($lines.Count -eq 0) {
            return ''
        }

        $startLine = [int](Get-MapValue -Map $ToolInput -Keys @('startLine', 'start_line') -Default 1)
        $endLine = [int](Get-MapValue -Map $ToolInput -Keys @('endLine', 'end_line') -Default $startLine)

        if ($startLine -lt 1) {
            $startLine = 1
        }

        if ($endLine -lt $startLine) {
            $endLine = $startLine
        }

        $startIndex = $startLine - 1
        if ($startIndex -ge $lines.Count) {
            return ''
        }

        $endIndex = [Math]::Min($lines.Count - 1, $endLine - 1)
        return ($lines[$startIndex..$endIndex] -join "`n")
    } catch {
        return $null
    }
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

$hookEventRaw = [string](Get-MapValue -Map $hookData -Keys @('hook_event_name', 'hookEventName', 'eventName', 'event'))
$hookEvent = Normalize-HookEventName -Name $hookEventRaw
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

$externalToolsRegex = if ($config.Contains('externalToolsRegex')) { [string]$config['externalToolsRegex'] } else { '^(search_web|fetch_webpage|web_fetch|mcp_.*|github_.*|github_repo|task|bash|powershell)$' }
$sensitiveFilenameRegex = if ($config.Contains('sensitiveFilenameRegex')) { [string]$config['sensitiveFilenameRegex'] } else { '(^|[\\/])\d{9,16}(\.[^\\/]+)?$' }
$sensitiveFilenameValidator = if ($config.Contains('sensitiveFilenameValidator')) { [string]$config['sensitiveFilenameValidator'] } else { '' }
$denyPathRegex = if ($config.Contains('denyPathRegex')) { [string]$config['denyPathRegex'] } else { '(^|[\\/])(\.env[^\\/]*|.*\.(pem|key|p12|pfx|crt|cer|der|sql|dump|bak|backup|csv|tsv|xlsx|xls|parquet|avro|har|log))$|(^|[\\/])(data|exports|dumps|logs|fixtures[\\/]prod|prod-fixtures|customer-data|payment-data)([\\/]|$)' }
$denyShellCommandRegex = if ($config.Contains('denyShellCommandRegex')) { [string]$config['denyShellCommandRegex'] } else { '(?i)\b(curl|wget|Invoke-WebRequest|Invoke-RestMethod|iwr|irm|scp|sftp|ftp|nc|ncat|telnet|rsync|aws\s+s3|az\s+storage|gcloud\s+(storage|compute)|gh\s+gist|pastebinit)\b' }

switch ($hookEvent) {
    'SessionStart' {
        Write-ContextOutput -HookEvent $hookEvent -Context $script:PolicyContext
        exit 0
    }

    'UserPromptSubmit' {
        $prompt = [string](Get-MapValue -Map $hookData -Keys @('prompt') -Default '')
        $matchedPatterns = Get-MatchedPatterns -Text $prompt -Patterns $patterns

        if ($matchedPatterns.Count -gt 0) {
            $matchedPatternNames = (Get-PatternDisplayNames -Patterns $matchedPatterns) -join ', '
            $maskedPrompt = Get-PreviewText -Text (Invoke-MaskText -Text $prompt -Patterns $patterns)
            $action = Resolve-EnforcementAction -HookEvent $hookEvent -MatchedPatterns $matchedPatterns

            if ($action -eq 'stop') {
                Write-CommonStopOutput -Reason "Sensitive patterns detected in user prompt: $matchedPatternNames" -SystemMessage ("Sensitive data detected in the prompt field. Masked preview:`n$maskedPrompt")
                exit 0
            }

            Write-CommonStopOutput -Reason '' -SystemMessage ("Sensitive data detected in the prompt field. Best-effort masked preview:`n$maskedPrompt")
            exit 0
        }

        exit 0
    }

    'PreCompact' {
        Write-HookOutput @{
            systemMessage = '[SECURITY] Before compacting context, preserve only masked placeholders. Never compact raw sensitive values.'
        }
        exit 0
    }

    'SubagentStart' {
        Write-ContextOutput -HookEvent $hookEvent -Context 'SECURITY POLICY (inherited): sensitive-data masking is active. Use only [MASKED-*] placeholders and never reconstruct originals.'
        exit 0
    }

    'PermissionRequest' {
        $toolName = [string](Get-MapValue -Map $hookData -Keys @('toolName', 'tool_name') -Default 'unknown')
        $toolArgsValue = Get-MapValue -Map $hookData -Keys @('toolArgs', 'tool_args', 'tool_input', 'toolInput', 'input') -Default @{}
        $toolArgsJson = Convert-ToJsonText -Value $toolArgsValue
        $matchedPatterns = Get-MatchedPatterns -Text $toolArgsJson -Patterns $patterns

        if ($matchedPatterns.Count -gt 0) {
            $matchedPatternNames = (Get-PatternDisplayNames -Patterns $matchedPatterns) -join ', '
            $maskedArgs = Get-PreviewText -Text (Invoke-MaskText -Text $toolArgsJson -Patterns $patterns)
            $action = Resolve-EnforcementAction -HookEvent $hookEvent -MatchedPatterns $matchedPatterns

            if ($action -eq 'interrupt') {
                Write-PermissionRequestDecision -Behavior 'deny' -Message "Sensitive patterns detected in permission request for '$toolName': $matchedPatternNames. Masked preview:`n$maskedArgs" -Interrupt
                exit 0
            }

            if ($action -eq 'deny') {
                Write-PermissionRequestDecision -Behavior 'deny' -Message "Sensitive patterns detected in permission request for '$toolName': $matchedPatternNames. Masked preview:`n$maskedArgs"
                exit 0
            }

            Write-PermissionRequestAllow -Message "Sensitive data detected in permission request for '$toolName'. Best-effort masked preview:`n$maskedArgs"
            exit 0
        }

        exit 0
    }

    # All tool decisions live in one branch so the hook flow is easy to inspect.
    'PreToolUse' {
        $toolName = [string](Get-MapValue -Map $hookData -Keys @('tool_name', 'toolName') -Default 'unknown')
        $toolInputValue = Get-MapValue -Map $hookData -Keys @('tool_input', 'toolInput', 'input', 'toolArgs') -Default @{}
        $toolInputMap = Convert-ToHashtable -Value $toolInputValue
        $toolInputJson = Convert-ToJsonText -Value $toolInputValue
        $matchedInputPatterns = Get-MatchedPatterns -Text $toolInputJson -Patterns $patterns

        if ([string]::IsNullOrWhiteSpace($toolInputJson) -or $toolInputJson -eq '{}' -or $toolInputJson -eq 'null') {
            exit 0
        }

        $toolPath = Get-ToolPath -ToolInput $toolInputMap
        $resolvedPath = $null
        if (-not [string]::IsNullOrWhiteSpace($toolPath)) {
            $resolvedPath = Resolve-ToolPath -ToolPath $toolPath -WorkspaceRoot $workspaceRoot
        }

        if (Test-ConfiguredRegexMatch -Text $toolPath -Regex $denyPathRegex) {
            Write-DecisionOutput -HookEvent $hookEvent -Decision 'deny' -Reason "Access to '$toolPath' was denied by sensitive path policy."
            exit 0
        }

        if (Test-ShellTool -ToolName $toolName) {
            $toolCommand = Get-ToolCommand -ToolInput $toolInputMap

            if ($null -ne $toolCommand) {
                $action = Resolve-EnforcementAction -HookEvent $hookEvent -MatchedPatterns $matchedInputPatterns
                $matchedPatternNames = (Get-PatternDisplayNames -Patterns $matchedInputPatterns) -join ', '

                if (Test-ConfiguredRegexMatch -Text $toolCommand.Value -Regex $denyShellCommandRegex) {
                    Write-DecisionOutput -HookEvent $hookEvent -Decision 'deny' -Reason 'Shell command was denied by exfiltration policy. Use a local-only command or ask for explicit review.'
                    exit 0
                }

                if ($matchedInputPatterns.Count -gt 0 -and $action -eq 'deny') {
                    Write-DecisionOutput -HookEvent $hookEvent -Decision 'deny' -Reason "Sensitive patterns detected in shell input: $matchedPatternNames. Tool execution was denied."
                    exit 0
                }

                $wrapperPath = Get-CommandOutputWrapperPath -ScriptDir $scriptDir
                if (-not (Test-Path $wrapperPath -PathType Leaf)) {
                    Write-DecisionOutput -HookEvent $hookEvent -Decision 'deny' -Reason 'Shell output masking wrapper was not found. Tool execution was denied to avoid exposing raw output.'
                    exit 0
                }

                if ([string]::IsNullOrWhiteSpace($script:MaskDataConfigPath)) {
                    Write-DecisionOutput -HookEvent $hookEvent -Decision 'deny' -Reason 'Masking config path was unavailable. Tool execution was denied to avoid exposing raw output.'
                    exit 0
                }

                $maskedShellInput = Convert-ToHashtable -Value (Invoke-MaskValue -Value $toolInputValue -Patterns $patterns)
                $maskedToolCommand = Get-ToolCommand -ToolInput $maskedShellInput
                if ($null -eq $maskedToolCommand) {
                    Write-DecisionOutput -HookEvent $hookEvent -Decision 'deny' -Reason 'Shell command field was unavailable after masking. Tool execution was denied to avoid exposing raw output.'
                    exit 0
                }

                $wrappedCommand = New-MaskedShellCommand -ToolName $toolName -Command $maskedToolCommand.Value -WrapperPath $wrapperPath -ConfigPath $script:MaskDataConfigPath
                $modifiedShellArgs = Update-ToolCommand -ToolInput $maskedShellInput -CommandKey $maskedToolCommand.Key -NewCommand $wrappedCommand

                Write-DecisionOutput -HookEvent $hookEvent -Decision 'allow' -Reason "Shell command output will be masked before it is returned to the model." -ModifiedArgs $modifiedShellArgs
                exit 0
            }
        }

        if ([regex]::IsMatch($toolName, $externalToolsRegex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) -and $matchedInputPatterns.Count -gt 0) {
            $modifiedExternalArgs = Convert-ToHashtable -Value (Invoke-MaskValue -Value $toolInputValue -Patterns $patterns)
            $action = Resolve-EnforcementAction -HookEvent $hookEvent -MatchedPatterns $matchedInputPatterns
            $matchedPatternNames = (Get-PatternDisplayNames -Patterns $matchedInputPatterns) -join ', '

            if ($action -eq 'deny') {
                Write-DecisionOutput -HookEvent $hookEvent -Decision 'deny' -Reason "Sensitive patterns detected in input to '$toolName': $matchedPatternNames. Tool execution was denied."
                exit 0
            }

            Write-DecisionOutput -HookEvent $hookEvent -Decision 'allow' -Reason "Sensitive data detected in input to '$toolName'. The tool arguments were masked before sending them onward." -ModifiedArgs $modifiedExternalArgs
            exit 0
        }

        if (-not [string]::IsNullOrWhiteSpace($toolPath) -and (Test-ConfiguredRegexMatch -Text $toolPath -Regex $sensitiveFilenameRegex -Validator $sensitiveFilenameValidator)) {
            if ($toolName -in @('view', 'read_file', 'readFile') -and -not [string]::IsNullOrWhiteSpace($resolvedPath) -and (Test-Path $resolvedPath -PathType Leaf)) {
                $pathContent = Get-Content -Path $resolvedPath -Raw -Encoding UTF8
                $maskedPathContent = Invoke-MaskText -Text $pathContent -Patterns $patterns
                $maskedPath = Get-MaskedTempPath -SourcePath $resolvedPath
                Write-Utf8File -Path $maskedPath -Content $maskedPathContent
                $modifiedPathArgs = Update-ToolPath -ToolInput $toolInputMap -NewPath $maskedPath

                Write-DecisionOutput -HookEvent $hookEvent -Decision 'allow' -Reason 'Sensitive numeric filename was redirected to a masked temporary copy.' -ModifiedArgs $modifiedPathArgs
                exit 0
            }

            Write-DecisionOutput -HookEvent $hookEvent -Decision 'deny' -Reason 'Sensitive numeric filename detected and no safe masked replacement was available. Tool execution was denied.'
            exit 0
        }

        if ($toolName -in @('view', 'read_file', 'readFile')) {
            if (-not [string]::IsNullOrWhiteSpace($resolvedPath) -and (Test-Path $resolvedPath -PathType Leaf)) {
                $fileContent = Get-Content -Path $resolvedPath -Raw -Encoding UTF8
                $matchedFilePatterns = Get-MatchedPatterns -Text $fileContent -Patterns $patterns

                if ($matchedFilePatterns.Count -gt 0) {
                    $maskedContent = Invoke-MaskText -Text $fileContent -Patterns $patterns
                    $matchedPatternNames = (Get-PatternDisplayNames -Patterns $matchedFilePatterns) -join ', '
                    $action = Resolve-EnforcementAction -HookEvent $hookEvent -MatchedPatterns $matchedFilePatterns

                    if ($action -eq 'deny') {
                        $maskedContentPreview = Get-PreviewText -Text $maskedContent
                        Write-DecisionOutput -HookEvent $hookEvent -Decision 'deny' -Reason "Sensitive patterns detected in file content: $matchedPatternNames. Masked preview:`n$maskedContentPreview"
                        exit 0
                    }

                    $maskedPath = Get-MaskedTempPath -SourcePath $resolvedPath
                    Write-Utf8File -Path $maskedPath -Content $maskedContent
                    $modifiedPathArgs = Update-ToolPath -ToolInput $toolInputMap -NewPath $maskedPath

                    Write-DecisionOutput -HookEvent $hookEvent -Decision 'allow' -Reason 'Sensitive data was detected in file content. The read was redirected to a masked temporary copy.' -ModifiedArgs $modifiedPathArgs
                    exit 0
                }
            }
        }

        $maskedInputValue = Invoke-MaskValue -Value $toolInputValue -Patterns $patterns
        $maskedInputJson = Convert-ToJsonText -Value $maskedInputValue
        if ($maskedInputJson -ne $toolInputJson) {
            $modifiedArgs = Convert-ToHashtable -Value $maskedInputValue
            $action = Resolve-EnforcementAction -HookEvent $hookEvent -MatchedPatterns $matchedInputPatterns
            $matchedPatternNames = (Get-PatternDisplayNames -Patterns $matchedInputPatterns) -join ', '

            if ($action -eq 'deny') {
                Write-DecisionOutput -HookEvent $hookEvent -Decision 'deny' -Reason "Sensitive patterns detected in tool input: $matchedPatternNames. Tool execution was denied."
                exit 0
            }

            Write-DecisionOutput -HookEvent $hookEvent -Decision 'allow' -Reason 'Sensitive data was detected and masked before tool execution.' -ModifiedArgs $modifiedArgs
            exit 0
        }

        exit 0
    }

    'PostToolUse' {
        $toolName = [string](Get-MapValue -Map $hookData -Keys @('tool_name', 'toolName') -Default 'unknown')
        $toolInputValue = Get-MapValue -Map $hookData -Keys @('tool_input', 'toolInput', 'input', 'toolArgs') -Default @{}
        $toolInputMap = Convert-ToHashtable -Value $toolInputValue
        $toolResultValue = Get-MapValue -Map $hookData -Keys @('tool_result', 'toolResult', 'tool_response', 'toolResponse') -Default $null
        if (($null -eq $toolResultValue -or [string]::IsNullOrWhiteSpace([string]$toolResultValue)) -and $toolInputMap.Count -gt 0) {
            $fallbackResult = Get-ToolReadContent -ToolName $toolName -ToolInput $toolInputMap -WorkspaceRoot $workspaceRoot
            if ($null -ne $fallbackResult) {
                $toolResultValue = $fallbackResult
            }
        }
        $toolResultJson = Convert-ToJsonText -Value $toolResultValue
        $matchedPatterns = Get-MatchedPatterns -Text $toolResultJson -Patterns $patterns

        if (-not [string]::IsNullOrWhiteSpace($toolResultJson) -and $toolResultJson -ne '{}' -and $toolResultJson -ne 'null' -and $matchedPatterns.Count -gt 0) {
            $maskedResultValue = Invoke-MaskValue -Value $toolResultValue -Patterns $patterns
            $maskedResult = Get-PreviewText -Text (Convert-ToJsonText -Value $maskedResultValue)
            $additionalContext = "SECURITY: '$toolName' returned sensitive data. Continue with this masked result only:`n$maskedResult"
            $action = Resolve-EnforcementAction -HookEvent $hookEvent -MatchedPatterns $matchedPatterns
            $matchedPatternNames = (Get-PatternDisplayNames -Patterns $matchedPatterns) -join ', '

            if ($action -eq 'block') {
                Write-PostToolUseContextOutput -SystemMessage "Sensitive data appeared in result from '$toolName'." -AdditionalContext $additionalContext -Block -Reason "Sensitive patterns detected in tool result: $matchedPatternNames"
                exit 0
            }

            Write-PostToolUseContextOutput -SystemMessage "Sensitive data appeared in result from '$toolName'. A masked preview was generated." -AdditionalContext $additionalContext
            exit 0
        }

        exit 0
    }

    'PostToolUseFailure' {
        $payloadJson = Convert-ToJsonText -Value $hookData

        if (Test-ContainsSensitive -Text $payloadJson -Patterns $patterns) {
            $maskedPayload = Get-PreviewText -Text (Convert-ToJsonText -Value (Invoke-MaskValue -Value $hookData -Patterns $patterns))
            Write-ContextOutput -HookEvent $hookEvent -Context "SECURITY: failure payload contained sensitive data. Use only this masked payload:`n$maskedPayload"
            exit 0
        }

        exit 0
    }

    'Stop' {
        if (Test-StopHookAlreadyActive -HookData $hookData) {
            exit 0
        }

        $transcriptPath = Get-TranscriptPath -HookData $hookData
        if (-not [string]::IsNullOrWhiteSpace($transcriptPath) -and (Test-Path $transcriptPath -PathType Leaf)) {
            $transcript = Get-Content -Path $transcriptPath -Raw -Encoding UTF8
            $matchedPatterns = Get-MatchedPatterns -Text $transcript -Patterns $patterns

            if ($matchedPatterns.Count -gt 0) {
                $maskedTranscript = Get-PreviewText -Text (Invoke-MaskText -Text $transcript -Patterns $patterns)
                $action = Resolve-EnforcementAction -HookEvent $hookEvent -MatchedPatterns $matchedPatterns
                $matchedPatternNames = (Get-PatternDisplayNames -Patterns $matchedPatterns) -join ', '

                if ($action -eq 'block') {
                    Write-StopContextOutput -HookEvent $hookEvent -SystemMessage 'Sensitive data detected before stop.' -Reason "Sensitive patterns detected before stop: $matchedPatternNames" -Block
                    exit 0
                }

                Write-StopContextOutput -HookEvent $hookEvent -SystemMessage 'Sensitive data detected before stop. Best-effort masked transcript preview generated.' -Reason ("SECURITY: use masked placeholders only. Preview:`n$maskedTranscript")
                exit 0
            }
        }

        exit 0
    }

    'SubagentStop' {
        if (Test-StopHookAlreadyActive -HookData $hookData) {
            exit 0
        }

        $transcriptPath = Get-TranscriptPath -HookData $hookData
        if (-not [string]::IsNullOrWhiteSpace($transcriptPath) -and (Test-Path $transcriptPath -PathType Leaf)) {
            $transcript = Get-Content -Path $transcriptPath -Raw -Encoding UTF8
            $matchedPatterns = Get-MatchedPatterns -Text $transcript -Patterns $patterns

            if ($matchedPatterns.Count -gt 0) {
                $maskedTranscript = Get-PreviewText -Text (Invoke-MaskText -Text $transcript -Patterns $patterns)
                $action = Resolve-EnforcementAction -HookEvent $hookEvent -MatchedPatterns $matchedPatterns
                $matchedPatternNames = (Get-PatternDisplayNames -Patterns $matchedPatterns) -join ', '

                if ($action -eq 'block') {
                    Write-StopContextOutput -HookEvent $hookEvent -SystemMessage 'Sensitive data detected in subagent transcript.' -Reason "Sensitive patterns detected in subagent transcript: $matchedPatternNames" -Block
                    exit 0
                }

                Write-StopContextOutput -HookEvent $hookEvent -SystemMessage 'Sensitive data detected in subagent transcript. Best-effort masked preview generated.' -Reason ("SECURITY: use masked placeholders only. Preview:`n$maskedTranscript")
                exit 0
            }
        }

        exit 0
    }

    'SessionEnd' {
        Write-Log "[$hookEvent] Session ended."
        exit 0
    }

    'ErrorOccurred' {
        $payloadJson = Convert-ToJsonText -Value $hookData
        $maskedPayload = Get-PreviewText -Text (Invoke-MaskText -Text $payloadJson -Patterns $patterns)
        Write-Log "[$hookEvent] $maskedPayload"
        exit 0
    }

    'Notification' {
        $message = [string](Get-MapValue -Map $hookData -Keys @('message') -Default '')

        if (Test-ContainsSensitive -Text $message -Patterns $patterns) {
            $maskedMessage = Get-PreviewText -Text (Invoke-MaskText -Text $message -Patterns $patterns)
            Write-HookOutput @{
                additionalContext = "SECURITY: notification contained sensitive data. Use only this masked message:`n$maskedMessage"
            }
            exit 0
        }

        exit 0
    }

    default {
        exit 0
    }
}
