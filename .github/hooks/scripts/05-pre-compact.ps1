#Requires -Version 5.1

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'HookDemoCommon.ps1')

$rawInput = Read-DemoRawInput
if ([string]::IsNullOrWhiteSpace($rawInput)) { exit 0 }
$hookData = Initialize-DemoContext -RawInput $rawInput
if (-not $hookData -or (Get-DemoHookEventName -HookData $hookData) -ne 'PreCompact') { exit 0 }

Write-DemoAudit 'PreCompact' 'Support escalation summary prepared for compacted context'
Write-DemoJsonOutput @{ systemMessage = 'Support demo reminder: compact only masked ticket notes, masked customer contacts, and safe action summaries.' }