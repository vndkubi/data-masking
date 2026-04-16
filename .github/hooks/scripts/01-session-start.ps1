#Requires -Version 5.1

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'HookDemoCommon.ps1')

$rawInput = Read-DemoRawInput
if ([string]::IsNullOrWhiteSpace($rawInput)) { exit 0 }
$hookData = Initialize-DemoContext -RawInput $rawInput
if (-not $hookData -or (Get-DemoHookEventName -HookData $hookData) -ne 'SessionStart') { exit 0 }

$logPath = Write-DemoStateLog -HookData $hookData -Summary 'Captured SessionStart payload for demo'
Write-DemoAudit 'SessionStart' "Logged SessionStart payload to $logPath"
Write-DemoJsonOutput @{
    hookSpecificOutput = @{
        hookEventName = 'SessionStart'
        additionalContext = "DEMO TRACE: SessionStart payload was logged to $logPath. Open the log file to see what Copilot sends when a session starts."
    }
}