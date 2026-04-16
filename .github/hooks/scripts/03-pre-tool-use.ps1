#Requires -Version 5.1

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'HookDemoCommon.ps1')

$rawInput = Read-DemoRawInput
if ([string]::IsNullOrWhiteSpace($rawInput)) { exit 0 }
$hookData = Initialize-DemoContext -RawInput $rawInput
if (-not $hookData -or (Get-DemoHookEventName -HookData $hookData) -ne 'PreToolUse') { exit 0 }

$toolName = Get-DemoToolName -HookData $hookData
$toolInputObj = Get-DemoToolInputObject -HookData $hookData
$toolInputJson = if ($toolInputObj) { ConvertTo-DemoJsonString $toolInputObj } else { '{}' }

if ($toolName -eq 'read_file' -or $toolName -eq 'readFile') {
    $filePath = if ($toolInputObj.filePath) { $toolInputObj.filePath } elseif ($toolInputObj.file_path) { $toolInputObj.file_path } elseif ($toolInputObj.path) { $toolInputObj.path } else { $null }
    if ($filePath) {
        if (-not [System.IO.Path]::IsPathRooted($filePath)) {
            $filePath = Join-Path $script:DemoCwd $filePath
        }
        if (Test-Path $filePath -PathType Leaf) {
            $fileContent = Get-Content $filePath -Raw -Encoding UTF8
            if ($fileContent -and (Test-DemoSensitive $fileContent)) {
                $maskedContent = Invoke-DemoMask $fileContent
                Write-DemoAudit 'PreToolUse' 'Returned sanitized ticket snapshot for read_file'
                Write-DemoJsonOutput @{
                    hookSpecificOutput = @{
                        hookEventName = 'PreToolUse'
                        permissionDecision = 'deny'
                        permissionDecisionReason = "SUPPORT DEMO: Raw ticket content contains customer contact data. Use this sanitized ticket snapshot instead:`n$maskedContent`nOnly quote the sanitized snapshot in your response."
                    }
                }
                exit 0
            }
        }
    }
}

if ([regex]::IsMatch($toolName, $script:DemoExternalToolsRegex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) -and (Test-DemoSensitive $toolInputJson)) {
    Write-DemoAudit 'PreToolUse' 'External support lookup paused for confirmation'
    Write-DemoJsonOutput @{
        hookSpecificOutput = @{
            hookEventName = 'PreToolUse'
            permissionDecision = 'ask'
            permissionDecisionReason = "Support demo safeguard: the external lookup '$toolName' includes customer contact data. Confirm that you want to send it, or mask it first."
        }
    }
    exit 0
}

if (Test-DemoSensitive $toolInputJson) {
    $maskedInput = Invoke-DemoMask $toolInputJson
    $updatedInput = try { $maskedInput | ConvertFrom-Json } catch { $maskedInput }
    Write-DemoAudit 'PreToolUse' 'Internal support action sanitized before tool execution'
    Write-DemoJsonOutput @{
        hookSpecificOutput = @{
            hookEventName = 'PreToolUse'
            permissionDecision = 'allow'
            permissionDecisionReason = 'Support action sanitized before tool execution'
            updatedInput = $updatedInput
            additionalContext = 'The support workflow may continue, but only with masked customer contact data.'
        }
    }
}