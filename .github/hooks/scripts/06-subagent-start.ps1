#Requires -Version 5.1

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'HookDemoCommon.ps1')

$rawInput = Read-DemoRawInput
if ([string]::IsNullOrWhiteSpace($rawInput)) { exit 0 }
$hookData = Initialize-DemoContext -RawInput $rawInput
if (-not $hookData -or (Get-DemoHookEventName -HookData $hookData) -ne 'SubagentStart') { exit 0 }

$agentType = if ($hookData.agent_type) { $hookData.agent_type } else { 'unknown' }
$logPath = Write-DemoStateLog -HookData $hookData -Summary "Captured SubagentStart payload for agent '$agentType'"
Write-DemoAudit 'SubagentStart' "Logged SubagentStart payload for $agentType to $logPath"
Write-DemoJsonOutput @{
    hookSpecificOutput = @{
        hookEventName = 'SubagentStart'
        additionalContext = "SubagentStart payload was logged to $logPath for agent '$agentType'. Use it to explain what context is passed to sub-agents."
    }
}