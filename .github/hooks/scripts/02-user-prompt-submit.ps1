#Requires -Version 5.1

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'HookDemoCommon.ps1')

$rawInput = Read-DemoRawInput
if ([string]::IsNullOrWhiteSpace($rawInput)) { exit 0 }
$hookData = Initialize-DemoContext -RawInput $rawInput
if (-not $hookData -or (Get-DemoHookEventName -HookData $hookData) -ne 'UserPromptSubmit') { exit 0 }

$prompt = if ($hookData.prompt) { $hookData.prompt } else { $null }
$maskedPrompt = if ($prompt) { Invoke-DemoMask $prompt } else { '' }
$logPath = Write-DemoStateLog -HookData $hookData -Summary 'Captured UserPromptSubmit payload for demo'
Write-DemoAudit 'UserPromptSubmit' "Logged UserPromptSubmit payload to $logPath"
Write-DemoJsonOutput @{
    hookSpecificOutput = @{
        hookEventName = 'UserPromptSubmit'
        permissionDecision = 'allow'
        permissionDecisionReason = 'Demo trace saved for UserPromptSubmit'
        updatedInput = @{ prompt = $maskedPrompt }
        systemMessage = "UserPromptSubmit payload was logged to $logPath. Use the log file to show the sanitized prompt."
    }
}