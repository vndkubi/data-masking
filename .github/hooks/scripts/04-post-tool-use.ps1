#Requires -Version 5.1

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'HookDemoCommon.ps1')

$rawInput = Read-DemoRawInput
if ([string]::IsNullOrWhiteSpace($rawInput)) { exit 0 }
$hookData = Initialize-DemoContext -RawInput $rawInput
if (-not $hookData -or (Get-DemoHookEventName -HookData $hookData) -ne 'PostToolUse') { exit 0 }

$toolName = Get-DemoToolName -HookData $hookData
$toolResponseObj = Get-DemoToolResponseObject -HookData $hookData
$toolResponseJson = if ($null -ne $toolResponseObj) { ConvertTo-DemoJsonString $toolResponseObj } else { '{}' }
$maskedResponse = Invoke-DemoMask $toolResponseJson
$logPath = Write-DemoStateLog -HookData $hookData -Summary "Captured PostToolUse payload for tool '$toolName'"
Write-DemoAudit 'PostToolUse' "Logged PostToolUse payload for $toolName to $logPath"
Write-DemoJsonOutput @{
    hookSpecificOutput = @{
        hookEventName = 'PostToolUse'
        additionalContext = "PostToolUse payload was logged to $logPath. Sanitized response preview:`n$maskedResponse"
    }
}