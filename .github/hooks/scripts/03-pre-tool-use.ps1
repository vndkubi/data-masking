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
$maskedInputJson = Invoke-DemoMask $toolInputJson
$updatedInput = try { $maskedInputJson | ConvertFrom-Json } catch { $maskedInputJson }
$logPath = Write-DemoStateLog -HookData $hookData -Summary "Captured PreToolUse payload for tool '$toolName'"
Write-DemoAudit 'PreToolUse' "Logged PreToolUse payload for $toolName to $logPath"
Write-DemoJsonOutput @{
    hookSpecificOutput = @{
        hookEventName = 'PreToolUse'
        permissionDecision = 'allow'
        permissionDecisionReason = "Demo trace saved for PreToolUse (tool: $toolName)"
        updatedInput = $updatedInput
        additionalContext = "PreToolUse payload was logged to $logPath. Use the log file to explain what the hook receives before '$toolName' runs."
    }
}