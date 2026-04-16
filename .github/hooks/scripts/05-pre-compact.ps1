#Requires -Version 5.1

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'HookDemoCommon.ps1')

$rawInput = Read-DemoRawInput
if ([string]::IsNullOrWhiteSpace($rawInput)) { exit 0 }
$hookData = Initialize-DemoContext -RawInput $rawInput
if (-not $hookData -or (Get-DemoHookEventName -HookData $hookData) -ne 'PreCompact') { exit 0 }

$logPath = Write-DemoStateLog -HookData $hookData -Summary 'Captured PreCompact payload for demo'
Write-DemoAudit 'PreCompact' "Logged PreCompact payload to $logPath"
Write-DemoJsonOutput @{ systemMessage = "PreCompact payload was logged to $logPath. Use it to explain what Copilot sends before compaction." }