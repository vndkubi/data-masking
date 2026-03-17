# =============================================================
# Sensitive Data Masker - Copilot Agent Hook (PowerShell)
# Handles: SessionStart, UserPromptSubmit, PreToolUse,
#           PreCompact, SubagentStart
# =============================================================

# Force UTF-8 encoding (VS Code expects UTF-8, PS 5.1 defaults to UTF-16LE)
try {
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$ErrorActionPreference = "Stop"

# Early diagnostic breadcrumb (confirms script execution)
try {
    $diagDir = if ($PSScriptRoot) { Join-Path (Split-Path $PSScriptRoot -Parent) "logs" } else { "logs" }
    if (-not (Test-Path $diagDir)) { New-Item -ItemType Directory -Path $diagDir -Force | Out-Null }
    $diagFile = Join-Path $diagDir "hook-debug.log"
    $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    [System.IO.File]::AppendAllText($diagFile, "[$ts] Script invoked, PSScriptRoot=$PSScriptRoot`r`n")
} catch {}

# Read hook data from stdin (with error handling)
try {
    $inputJson = [Console]::In.ReadToEnd()
} catch {
    try { [System.IO.File]::AppendAllText($diagFile, "[$ts] STDIN READ FAILED: $_`r`n") } catch {}
    exit 0
}

if (-not $inputJson -or $inputJson.Trim().Length -eq 0) {
    try { [System.IO.File]::AppendAllText($diagFile, "[$ts] STDIN EMPTY - no hook data received`r`n") } catch {}
    exit 0
}

try {
    $inputData = $inputJson | ConvertFrom-Json
} catch {
    try { [System.IO.File]::AppendAllText($diagFile, "[$ts] JSON PARSE FAILED: $_`r`n") } catch {}
    exit 0
}

$hookEvent = if ($inputData.hook_event_name) { $inputData.hook_event_name } else { $inputData.hookEventName }
try { [System.IO.File]::AppendAllText($diagFile, "[$ts] Hook event: $hookEvent`r`n") } catch {}
try { [System.IO.File]::AppendAllText($diagFile, "[$ts] Raw JSON: $inputJson`r`n") } catch {}

# ==============================================================
# CONFIGURATION
# ==============================================================
$cwd = if ($inputData.cwd) { $inputData.cwd } else { "." }
$configPath = Join-Path $cwd ".github\hooks\masking-config.json"
$patterns = @()
$customPatterns = @()
$externalToolsRegex = "^(search_web|fetch_webpage|mcp_.*|github_repo)$"

if (Test-Path $configPath) {
    try {
        $configData = Get-Content -Path $configPath -Raw | ConvertFrom-Json
        if ($configData.patterns) {
            $patterns = $configData.patterns
        }
        if ($configData.customPatterns) {
            $customPatterns = $configData.customPatterns
        }
        if ($configData.externalToolsRegex) {
            $externalToolsRegex = $configData.externalToolsRegex
        }
    } catch {
        Write-AuditLog -Event "Config Error" -Detail "Failed to parse masking-config.json: $_"
    }
}
$allPatterns = $patterns + $customPatterns

# ==============================================================
# MASKING PATTERNS
# Order matters: longer digit patterns first to avoid partial matches
# ==============================================================

function Mask-SensitiveData {
    param([string]$Content)

    foreach ($p in $allPatterns) {
        $regex = $p.regex
        # Convert \N (bash/sed-style) backreferences to $N (PowerShell -replace style)
        $repl = if ($p.replacement) { $p.replacement -replace '\\([0-9]+)', '$$$1' } else { $p.name }
        $Content = $Content -replace $regex, $repl
    }

    return $Content
}

function Test-HasSensitiveData {
    param([string]$Content)

    if ($allPatterns.Count -eq 0) { return $false }
    $regexParts = $allPatterns | ForEach-Object { $_.regex }
    $combinedRegex = $regexParts -join "|"
    return $Content -match $combinedRegex
}
# ==============================================================
# AUDIT LOG
# ==============================================================

function Write-AuditLog {
    param(
        [string]$Event,
        [string]$Detail
    )
    try {
        $cwd = if ($inputData.cwd) { $inputData.cwd } else { "." }
        $logDir = Join-Path $cwd "logs"
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $logFile = Join-Path $logDir "copilot-mask-audit.log"
        $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        Add-Content -Path $logFile -Value "[$timestamp] [$Event] $Detail" -ErrorAction SilentlyContinue
    } catch {
        # Silently ignore logging errors
    }
}

# ==============================================================
# DISPATCH BY HOOK EVENT
# ==============================================================

switch ($hookEvent) {

    "PreToolUse" {
        $toolName = if ($inputData.tool_name) { $inputData.tool_name } elseif ($inputData.toolName) { $inputData.toolName } else { "unknown" }

        # Get tool input (VS Code may use: input, toolInput, tool_input, or toolArgs)
        $toolInput = if ($inputData.tool_input) { $inputData.tool_input } elseif ($inputData.toolInput) { $inputData.toolInput } elseif ($inputData.input) { $inputData.input } elseif ($inputData.toolArgs) { $inputData.toolArgs } else { $null }

        # If toolInput is a JSON string, parse it into an object
        if ($toolInput -is [string] -and $toolInput.TrimStart().StartsWith('{')) {
            try {
                $toolInput = $toolInput | ConvertFrom-Json
            } catch {}
        }

        Write-AuditLog -Event "PreToolUse-Debug" -Detail "tool=$toolName, hasInput=$($null -ne $toolInput), inputType=$($toolInput.GetType().Name), keys=$($inputData.PSObject.Properties.Name -join ',')"

        if ($toolInput) {
            $toolInputStr = if ($toolInput -is [string]) { $toolInput } else { $toolInput | ConvertTo-Json -Depth 10 -Compress }

            # --- Egress Protection: DENY external tools if they contain ANY sensitive data ---
            if ($toolName -match $externalToolsRegex) {
                if (Test-HasSensitiveData -Content $toolInputStr) {
                    Write-AuditLog -Event "PreToolUse (Egress)" -Detail "CONFIRM REQUIRED: External tool '$toolName' contains sensitive data."
                    
                    $output = @{
                        hookSpecificOutput = @{
                            hookEventName = "PreToolUse"
                            permissionDecision = "ask"
                            permissionDecisionReason = "Sensitive data detected in the input to '$toolName'. Do you want to send this data to the external service? If yes, consider whether the data should be masked first."
                        }
                    }
                    [Console]::Out.WriteLine(($output | ConvertTo-Json -Depth 5 -Compress))
                    exit 0
                }
            }

            # --- Strategy 1: DENY file operations with sensitive file paths ---
            # Check if any file path in tool input contains sensitive patterns (from config)
            $hasSensitivePath = $false
            $matchedPattern = ""
            foreach ($p in $allPatterns) {
                if ($toolInputStr -match "(?i)(filePath|file_path|path|file)[^}]*($($p.regex))") {
                    $hasSensitivePath = $true
                    $matchedPattern = $p.name
                    break
                }
            }
            Write-AuditLog -Event "Strategy1-Debug" -Detail "tool=$toolName | patterns_checked=$($allPatterns.Count) | matched=$hasSensitivePath | pattern='$matchedPattern' | input_len=$($toolInputStr.Length)"

            if ($hasSensitivePath) {
                $matchedPath = if ($toolInputStr -match '(?i)(filePath|file_path|path)[^,}]*') { $Matches[0] } else { "(unknown)" }
                Write-AuditLog -Event "PreToolUse" -Detail "DENIED: File path with sensitive pattern in tool: $toolName | matched_path=$matchedPath | pattern=$matchedPattern"

                $output = @{
                    hookSpecificOutput = @{
                        hookEventName = "PreToolUse"
                        permissionDecision = "deny"
                        permissionDecisionReason = "BLOCKED by security policy: The file path contains a pattern matching sensitive data (e.g. 16-digit credit card number, 12-digit CCCD, or 9-digit CMND in the filename). Reading or modifying files with PII in the name is not allowed. Please rename the file to remove sensitive identifiers first."
                    }
                }
                [Console]::Out.WriteLine(($output | ConvertTo-Json -Depth 5 -Compress))
                exit 0
            }

            # --- Strategy 2: PRE-READ file content and deny if sensitive ---
            if ($toolName -eq "read_file" -or $toolName -eq "readFile") {
                $filePath = $null
                if ($toolInput.filePath) { $filePath = $toolInput.filePath }
                elseif ($toolInput.file_path) { $filePath = $toolInput.file_path }
                elseif ($toolInput.path) { $filePath = $toolInput.path }

                if ($filePath) {
                    if (-not [System.IO.Path]::IsPathRooted($filePath)) {
                        $cwd = if ($inputData.cwd) { $inputData.cwd } else { (Get-Location).Path }
                        $filePath = Join-Path $cwd $filePath
                    }
                    if (Test-Path $filePath) {
                        try {
                            $fileContent = Get-Content -Path $filePath -Raw -ErrorAction Stop
                            if ($fileContent -and (Test-HasSensitiveData -Content $fileContent)) {
                                $maskedContent = Mask-SensitiveData -Content $fileContent
                                Write-AuditLog -Event "PreToolUse" -Detail "DENIED read_file: sensitive content in $filePath"

                                $output = @{
                                    hookSpecificOutput = @{
                                        hookEventName = "PreToolUse"
                                        permissionDecision = "deny"
                                        permissionDecisionReason = "SECURITY: File contains sensitive data. Here is the sanitized content:`n$maskedContent`nIMPORTANT: Use ONLY this masked version. Read only masked content."
                                    }
                                }
                                [Console]::Out.WriteLine(($output | ConvertTo-Json -Depth 5 -Compress))
                                exit 0
                            }
                        } catch {
                            # Can't pre-read file - fall through to allow
                        }
                    }
                }
            }

            # --- Strategy 3: MASK sensitive data in tool arguments (commands, etc.) ---
            $maskedStr = Mask-SensitiveData -Content $toolInputStr

            if ($toolInputStr -ne $maskedStr) {
                Write-AuditLog -Event "PreToolUse" -Detail "Sensitive data masked in tool: $toolName"

                try {
                    $updatedInput = $maskedStr | ConvertFrom-Json
                } catch {
                    $updatedInput = $maskedStr
                }

                $output = @{
                    hookSpecificOutput = @{
                        hookEventName = "PreToolUse"
                        permissionDecision = "allow"
                        permissionDecisionReason = "Sensitive data was detected and masked before tool execution"
                        updatedInput = $updatedInput
                        additionalContext = "WARNING: Sensitive data was detected in tool input and has been automatically masked with [MASKED-*] placeholders. Do NOT attempt to unmask, recover, or reconstruct the original values."
                    }
                }
                [Console]::Out.WriteLine(($output | ConvertTo-Json -Depth 5 -Compress))
                exit 0
            }
        }
        # No sensitive data found - allow silently
    }

    "SessionStart" {
        Write-AuditLog -Event "SessionStart" -Detail "Session initialized with sensitive-data masking policy"

        $context = @"
SECURITY POLICY ACTIVE - SENSITIVE DATA MASKING:
Sensitive data in this session has been automatically masked with [MASKED-*] placeholders.

RULES:
1. Always use the masked placeholder (e.g. [MASKED-CC], [MASKED-KEY], [MASKED-ID]) when referencing sensitive values - never reconstruct or reveal the originals.
2. When passing data to ANY tool call, external service, MCP tool, or API - use ONLY the masked version.
3. When storing or summarising information into context (memory, compaction, subagent hand-off) - use ONLY the masked version.
4. If you receive a [MASKED-*] value, treat it as the real value. Do NOT attempt to recover, guess, or reconstruct the original.

Masking applies to: credit card numbers, national IDs (CMND/CCCD), API keys, Bearer tokens, passwords, phone numbers, bank accounts, connection strings, AWS keys, and private keys.

CRITICAL FILENAME SECURITY RULE:
- If workspace_info contains filenames that are purely numeric with 9-16 digits (pattern: \d{9,16}), treat such filenames as [MASKED-FILENAME].
- NEVER repeat, reference, or use such filenames in tool calls, commands, or responses.
- If you need to operate on such a file, ask the user to confirm using only the [MASKED-FILENAME] placeholder.
"@

        $output = @{
            hookSpecificOutput = @{
                hookEventName = "SessionStart"
                additionalContext = $context
            }
        }
        [Console]::Out.WriteLine(($output | ConvertTo-Json -Depth 5 -Compress))
    }

    "UserPromptSubmit" {
        $prompt = $inputData.prompt
        if ($prompt -and (Test-HasSensitiveData -Content $prompt)) {
            $maskedPrompt = Mask-SensitiveData -Content $prompt
            Write-AuditLog -Event "UserPromptSubmit" -Detail "Sensitive data pattern detected and masked in user prompt"

            $output = @{
                hookSpecificOutput = @{
                    hookEventName = "UserPromptSubmit"
                    permissionDecision = "allow"
                    permissionDecisionReason = "Sensitive data masked in prompt"
                    updatedInput = @{
                        prompt = $maskedPrompt
                    }
                    systemMessage = "WARNING: Sensitive data was detected in your prompt and has been automatically masked. The AI will only see the sanitized version."
                }
            }
            [Console]::Out.WriteLine(($output | ConvertTo-Json -Depth 5 -Compress))
            exit 0
        }
    }

    "PreCompact" {
        Write-AuditLog -Event "PreCompact" -Detail "Context compaction triggered - masking policy reminder injected"

        $output = @{
            systemMessage = "Pre-compaction reminder: Sensitive data masking is active. Ensure no unmasked credentials, PII, API keys, or confidential data persists in the compacted context."
        }
        [Console]::Out.WriteLine(($output | ConvertTo-Json -Depth 3 -Compress))
    }

    "SubagentStart" {
        $agentType = if ($inputData.agent_type) { $inputData.agent_type } else { "unknown" }
        Write-AuditLog -Event "SubagentStart" -Detail "Subagent spawned: $agentType - masking policy injected"

        $output = @{
            hookSpecificOutput = @{
                hookEventName = "SubagentStart"
                additionalContext = "SECURITY POLICY (inherited): Sensitive-data masking is active. The following are automatically masked: credit card numbers, API keys, Bearer tokens, passwords, phone numbers, national ID numbers (CMND/CCCD), bank accounts, connection strings, AWS keys, and private keys. All masked values appear as [MASKED-*]. Do NOT attempt to unmask or reconstruct them."
            }
        }
        [Console]::Out.WriteLine(($output | ConvertTo-Json -Depth 5 -Compress))
    }

    "PostToolUse" {
        $toolName = if ($inputData.tool_name) { $inputData.tool_name } elseif ($inputData.toolName) { $inputData.toolName } else { "unknown" }
        # VS Code may use: tool_response, toolResponse, or output
        $toolResponseRaw = if ($inputData.tool_response) { $inputData.tool_response } elseif ($inputData.toolResponse) { $inputData.toolResponse } elseif ($inputData.output) { $inputData.output } else { $null }

        # If toolResponseRaw is a JSON string, parse it
        if ($toolResponseRaw -is [string] -and $toolResponseRaw.TrimStart().StartsWith('{')) {
            try {
                $toolResponseRaw = $toolResponseRaw | ConvertFrom-Json
            } catch {}
        }

        Write-AuditLog -Event "PostToolUse-Debug" -Detail "tool=$toolName, hasResponse=$($null -ne $toolResponseRaw), responseType=$($toolResponseRaw.GetType().Name), keys=$($inputData.PSObject.Properties.Name -join ',')"

        if ($toolResponseRaw) {
            $toolResponseStr = if ($toolResponseRaw -is [string]) { $toolResponseRaw } else { $toolResponseRaw | ConvertTo-Json -Depth 10 -Compress }

            if (Test-HasSensitiveData -Content $toolResponseStr) {
                $maskedResponse = Mask-SensitiveData -Content $toolResponseStr
                Write-AuditLog -Event "PostToolUse" -Detail "Sensitive data masked in tool response: $toolName"

                $output = @{
                    hookSpecificOutput = @{
                        hookEventName = "PostToolUse"
                        additionalContext = "CRITICAL SECURITY ALERT: The tool '$toolName' returned sensitive data. ALL sensitive values have been masked. You MUST use ONLY this sanitized version in your response:`n$maskedResponse`nDo NOT display the original tool output. Display ONLY the masked version above."
                    }
                }
                [Console]::Out.WriteLine(($output | ConvertTo-Json -Depth 5 -Compress))
            }
        }
    }

    default {
        # Unknown hook event - pass through silently
    }
}

exit 0