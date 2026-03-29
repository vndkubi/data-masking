#Requires -Version 5.1
# =============================================================
# Sensitive Data Masker - Copilot Agent Hook (Windows/PowerShell)
# Handles: SessionStart, UserPromptSubmit, PreToolUse,
#           PreCompact, SubagentStart, PostToolUse
# Platform: Windows PowerShell 5.1+ / PowerShell Core 7+
# No external dependencies - pure PowerShell (.NET regex)
# =============================================================

$ErrorActionPreference = "Continue"

# ==============================================================
# TIMESTAMP / DIAGNOSTICS
# ==============================================================
function Get-Ts {
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$DiagDir    = Join-Path (Split-Path -Parent $ScriptDir) "logs"
try { New-Item -ItemType Directory -Force -Path $DiagDir | Out-Null } catch {}
$DiagFile   = Join-Path $DiagDir "hook-debug.log"

function Write-DiagLog {
    param([string]$Message)
    try { Add-Content -Path $DiagFile -Value "[$(Get-Ts)] $Message" -Encoding UTF8 } catch {}
}

function Write-AuditLog {
    param([string]$Event, [string]$Detail)
    try { Add-Content -Path $script:AuditFile -Value "[$(Get-Ts)] [$Event] $Detail" -Encoding UTF8 } catch {}
}

Write-DiagLog "Script invoked, ScriptDir=$ScriptDir"

# ==============================================================
# READ STDIN
# ==============================================================
try {
    $rawInput = [Console]::In.ReadToEnd()
} catch {
    $rawInput = ""
}

if ([string]::IsNullOrWhiteSpace($rawInput)) {
    Write-DiagLog "STDIN EMPTY - no hook data received"
    exit 0
}

# ==============================================================
# PARSE JSON INPUT
# ==============================================================
try {
    $hookData = $rawInput | ConvertFrom-Json
} catch {
    Write-DiagLog "JSON PARSE FAILED: $_"
    exit 0
}

$hookEvent = if ($hookData.hook_event_name) { $hookData.hook_event_name }
             elseif ($hookData.hookEventName) { $hookData.hookEventName }
             else { $null }

if (-not $hookEvent) {
    Write-DiagLog "No hookEventName found in input"
    exit 0
}

Write-DiagLog "Hook event: $hookEvent"

# ==============================================================
# CONFIGURATION
# ==============================================================
$cwd = if ($hookData.cwd) { $hookData.cwd } else { "." }
$configPath = Join-Path $cwd ".github\hooks\masking-config.json"
$externalToolsRegex = "^(search_web|fetch_webpage|mcp_.*|github_repo)$"

$config = $null
if (Test-Path $configPath) {
    try {
        # masking-config.json uses JSONC syntax (// comments + trailing commas).
        # Strip both before parsing — ConvertFrom-Json requires standard JSON.
        $rawJson = (Get-Content $configPath -Raw -Encoding UTF8) -replace '(?m)^\s*//.*$', ''
        # Strip trailing commas before ] or } (JSONC allows them, standard JSON doesn't)
        $rawJson = [regex]::Replace($rawJson, ',(?=\s*[}\]])', '')
        $config = $rawJson | ConvertFrom-Json
        if ($config.externalToolsRegex) {
            $externalToolsRegex = $config.externalToolsRegex
        }
    } catch {
        Write-DiagLog "Failed to load config: $_"
    }
}

# Audit log file (set after CWD is known)
$logDir = Join-Path $cwd "logs"
try { New-Item -ItemType Directory -Force -Path $logDir | Out-Null } catch {}
$script:AuditFile = Join-Path $logDir "copilot-mask-audit.log"

# ==============================================================
# MASKING
# ==============================================================
function Invoke-MaskSensitive {
    param([string]$Content)
    if (-not $config) { return $Content }

    $result = $Content

    if ($config.patterns) {
        foreach ($pattern in $config.patterns) {
            if ($null -ne $pattern.enabled -and $pattern.enabled -eq $false) { continue }
            $rx = if ($pattern.regex) { $pattern.regex } else { $null }
            if (-not $rx) { continue }
            $rep = if ($pattern.replacement) { $pattern.replacement }
                   elseif ($pattern.name)    { $pattern.name }
                   else                      { continue }
            try { $result = [regex]::Replace($result, $rx, $rep) } catch {}
        }
    }

    if ($config.customPatterns) {
        foreach ($cp in $config.customPatterns) {
            $rx  = $cp.regex
            $rep = if ($cp.replacement) { $cp.replacement } elseif ($cp.name) { $cp.name } else { $null }
            if ($rx -and $rep) {
                try { $result = [regex]::Replace($result, $rx, $rep) } catch {}
            }
        }
    }

    return $result
}

function Test-HasSensitive {
    param([string]$Content)
    if (-not $config) {
        return [regex]::IsMatch($Content, '[0-9]{16}')
    }
    $allPatterns = @()
    if ($config.patterns)       { $allPatterns += $config.patterns }
    if ($config.customPatterns) { $allPatterns += $config.customPatterns }
    foreach ($p in $allPatterns) {
        if ($null -ne $p.enabled -and $p.enabled -eq $false) { continue }
        $rx = $p.regex
        if ($rx) {
            try { if ([regex]::IsMatch($Content, $rx)) { return $true } } catch {}
        }
    }
    return $false
}

# ==============================================================
# JSON OUTPUT HELPER
# ==============================================================
function Write-JsonOutput {
    param([hashtable]$Object)
    $json = $Object | ConvertTo-Json -Depth 10 -Compress
    [Console]::Out.WriteLine($json)
}

# ==============================================================
# DISPATCH BY HOOK EVENT
# ==============================================================
switch ($hookEvent) {

    "PreToolUse" {
        $toolName = if ($hookData.tool_name) { $hookData.tool_name }
                    elseif ($hookData.toolName) { $hookData.toolName }
                    else { "unknown" }

        $toolInputObj = if ($null -ne $hookData.tool_input)  { $hookData.tool_input }
                        elseif ($null -ne $hookData.toolInput) { $hookData.toolInput }
                        elseif ($null -ne $hookData.input)     { $hookData.input }
                        elseif ($null -ne $hookData.toolArgs)  { $hookData.toolArgs }
                        else { $null }

        $toolInputStr = if ($toolInputObj) { $toolInputObj | ConvertTo-Json -Depth 10 -Compress } else { "{}" }

        $keys = ($hookData | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name) -join ","
        Write-AuditLog "PreToolUse-Debug" "tool=$toolName, keys=$keys"

        if ($toolInputStr -and $toolInputStr -ne "{}" -and $toolInputStr -ne "null") {

            # --- Egress Protection ---
            if ([regex]::IsMatch($toolName, $externalToolsRegex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                if (Test-HasSensitive $toolInputStr) {
                    Write-AuditLog "PreToolUse (Egress)" "CONFIRM REQUIRED: External tool '$toolName' contains sensitive data."
                    Write-JsonOutput @{
                        hookSpecificOutput = @{
                            hookEventName          = "PreToolUse"
                            permissionDecision     = "ask"
                            permissionDecisionReason = "Sensitive data detected in the input to '$toolName'. Do you want to send this data to the external service? If yes, consider whether the data should be masked first."
                        }
                    }
                    exit 0
                }
            }

            # --- Strategy 1: DENY file operations with sensitive file paths ---
            $pathRegex = ""
            if ($config) {
                $regexList = @()
                if ($config.patterns)       { $regexList += $config.patterns       | Where-Object { $_.regex } | ForEach-Object { $_.regex } }
                if ($config.customPatterns) { $regexList += $config.customPatterns | Where-Object { $_.regex } | ForEach-Object { $_.regex } }
                $pathRegex = $regexList -join "|"
            }
            if (-not $pathRegex) { $pathRegex = '[0-9]{16}' }

            Write-AuditLog "Strategy1-Debug" "tool=$toolName | regex_built=$(if ($pathRegex) {'yes'} else {'no'}) | input_len=$($toolInputStr.Length)"

            try {
                if ([regex]::IsMatch($toolInputStr, "(filePath|file_path|path|file)[^}]*($pathRegex)", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                    Write-AuditLog "PreToolUse" "DENIED: File path with sensitive pattern in tool: $toolName"
                    Write-JsonOutput @{
                        hookSpecificOutput = @{
                            hookEventName            = "PreToolUse"
                            permissionDecision       = "deny"
                            permissionDecisionReason = "BLOCKED by security policy: The file path contains a pattern matching sensitive data. Reading or modifying files with PII in the name is not allowed. Please rename the file to remove sensitive identifiers first."
                        }
                    }
                    exit 0
                }
            } catch {}

            # --- Strategy 2: PRE-READ file content and deny if sensitive ---
            if ($toolName -eq "read_file" -or $toolName -eq "readFile") {
                $filePath = if ($toolInputObj -and $toolInputObj.filePath)   { $toolInputObj.filePath }
                             elseif ($toolInputObj -and $toolInputObj.file_path) { $toolInputObj.file_path }
                             elseif ($toolInputObj -and $toolInputObj.path)  { $toolInputObj.path }
                             else { $null }

                if ($filePath) {
                    if (-not [System.IO.Path]::IsPathRooted($filePath)) {
                        $filePath = Join-Path $cwd $filePath
                    }
                    if (Test-Path $filePath -PathType Leaf) {
                        try {
                            $fileContent = Get-Content $filePath -Raw -Encoding UTF8
                            if ($fileContent -and (Test-HasSensitive $fileContent)) {
                                $maskedContent = Invoke-MaskSensitive $fileContent
                                Write-AuditLog "PreToolUse" "DENIED read_file: sensitive content in $filePath"
                                Write-JsonOutput @{
                                    hookSpecificOutput = @{
                                        hookEventName            = "PreToolUse"
                                        permissionDecision       = "deny"
                                        permissionDecisionReason = "SECURITY: File contains sensitive data. Here is the sanitized content:`n$maskedContent`nIMPORTANT: Use ONLY this masked version. Read only masked content."
                                    }
                                }
                                exit 0
                            }
                        } catch {}
                    }
                }
            }

            # --- Strategy 3: MASK sensitive data in tool arguments ---
            $maskedStr = Invoke-MaskSensitive $toolInputStr
            if ($toolInputStr -ne $maskedStr) {
                Write-AuditLog "PreToolUse" "Sensitive data masked in tool: $toolName"
                $updatedInput = try { $maskedStr | ConvertFrom-Json } catch { $maskedStr }
                Write-JsonOutput @{
                    hookSpecificOutput = @{
                        hookEventName            = "PreToolUse"
                        permissionDecision       = "allow"
                        permissionDecisionReason = "Sensitive data was detected and masked before tool execution"
                        updatedInput             = $updatedInput
                        additionalContext        = "WARNING: Sensitive data was detected in tool input and has been automatically masked with [MASKED-*] placeholders. Do NOT attempt to unmask, recover, or reconstruct the original values."
                    }
                }
                exit 0
            }
        }
        # No sensitive data found - allow silently
    }

    "SessionStart" {
        Write-JsonOutput @{
            hookSpecificOutput = @{
                hookEventName     = "SessionStart"
                additionalContext = "SECURITY POLICY ACTIVE - SENSITIVE DATA MASKING:`nSensitive data in this session has been automatically masked with [MASKED-*] placeholders.`n`nRULES:`n1. Always use the masked placeholder (e.g. [MASKED-CC], [MASKED-KEY], [MASKED-ID]) when referencing sensitive values - never reconstruct or reveal the originals.`n2. When passing data to ANY tool call, external service, MCP tool, or API - use ONLY the masked version.`n3. When storing or summarising information into context (memory, compaction, subagent hand-off) - use ONLY the masked version.`n4. If you receive a [MASKED-*] value, treat it as the real value. Do NOT attempt to recover, guess, or reconstruct the original.`n`nMasking applies to: credit card numbers, national IDs (CMND/CCCD), API keys, Bearer tokens, passwords, phone numbers, bank accounts, connection strings, AWS keys, and private keys.`n`nCRITICAL FILENAME SECURITY RULE:`n- If workspace_info contains filenames that are purely numeric with 16 digits (pattern: \d{16}), treat such filenames as [MASKED-FILENAME].`n- NEVER repeat, reference, or use such filenames in tool calls, commands, or responses.`n- If you need to operate on such a file, ask the user to confirm using only the [MASKED-FILENAME] placeholder."
            }
        }
        Write-AuditLog "SessionStart" "Session initialized with sensitive-data masking policy"
    }

    "UserPromptSubmit" {
        $prompt = if ($hookData.prompt) { $hookData.prompt } else { $null }
        if ($prompt -and (Test-HasSensitive $prompt)) {
            $maskedPrompt = Invoke-MaskSensitive $prompt
            Write-AuditLog "UserPromptSubmit" "Sensitive data pattern detected and masked in user prompt"
            Write-JsonOutput @{
                hookSpecificOutput = @{
                    hookEventName            = "UserPromptSubmit"
                    permissionDecision       = "allow"
                    permissionDecisionReason = "Sensitive data masked in prompt"
                    updatedInput             = @{ prompt = $maskedPrompt }
                    systemMessage            = "[WARNING] Sensitive data was detected in your prompt and has been automatically masked. The AI will only see the sanitized version."
                }
            }
        }
    }

    "PreCompact" {
        Write-AuditLog "PreCompact" "Context compaction triggered - masking policy reminder injected"
        Write-JsonOutput @{
            systemMessage = "[SECURITY] Pre-compaction reminder: Sensitive data masking is active. Ensure no unmasked credentials, PII, API keys, or confidential data persists in the compacted context."
        }
    }

    "SubagentStart" {
        $agentType = if ($hookData.agent_type) { $hookData.agent_type } else { "unknown" }
        Write-AuditLog "SubagentStart" "Subagent spawned: $agentType - masking policy injected"
        Write-JsonOutput @{
            hookSpecificOutput = @{
                hookEventName     = "SubagentStart"
                additionalContext = "SECURITY POLICY (inherited): Sensitive-data masking is active. The following are automatically masked: credit card numbers, API keys, Bearer tokens, passwords, phone numbers, national ID numbers (CMND/CCCD), bank accounts, connection strings, AWS keys, and private keys. All masked values appear as [MASKED-*]. Do NOT attempt to unmask or reconstruct them."
            }
        }
    }

    "PostToolUse" {
        $toolName = if ($hookData.tool_name) { $hookData.tool_name }
                    elseif ($hookData.toolName) { $hookData.toolName }
                    else { "unknown" }

        $toolResponseObj = if ($null -ne $hookData.tool_response)  { $hookData.tool_response }
                           elseif ($null -ne $hookData.toolResponse) { $hookData.toolResponse }
                           elseif ($null -ne $hookData.output)       { $hookData.output }
                           else { $null }

        $keys = ($hookData | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name) -join ","
        Write-AuditLog "PostToolUse-Debug" "tool=$toolName, keys=$keys"

        if ($null -ne $toolResponseObj) {
            $toolResponseStr = if ($toolResponseObj -is [string]) { $toolResponseObj }
                               else { $toolResponseObj | ConvertTo-Json -Depth 10 -Compress }
            if (Test-HasSensitive $toolResponseStr) {
                $maskedResponse = Invoke-MaskSensitive $toolResponseStr
                Write-AuditLog "PostToolUse" "Sensitive data masked in tool response: $toolName"
                Write-JsonOutput @{
                    hookSpecificOutput = @{
                        hookEventName     = "PostToolUse"
                        additionalContext = "CRITICAL SECURITY ALERT: The tool '$toolName' returned sensitive data. ALL sensitive values have been masked. You MUST use ONLY this sanitized version in your response:`n$maskedResponse`nDo NOT display the original tool output. Display ONLY the masked version above."
                    }
                }
            }
        }
    }

    default {
        # Unknown hook event - pass through silently
    }
}

exit 0
