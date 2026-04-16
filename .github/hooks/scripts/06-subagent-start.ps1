#Requires -Version 5.1

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'HookDemoCommon.ps1')

$rawInput = Read-DemoRawInput
if ([string]::IsNullOrWhiteSpace($rawInput)) { exit 0 }
$hookData = Initialize-DemoContext -RawInput $rawInput
if (-not $hookData -or (Get-DemoHookEventName -HookData $hookData) -ne 'SubagentStart') { exit 0 }

$agentType = if ($hookData.agent_type) { $hookData.agent_type } else { 'unknown' }
Write-DemoAudit 'SubagentStart' "Delegated sanitized support task to $agentType"
Write-DemoJsonOutput @{
    hookSpecificOutput = @{
        hookEventName = 'SubagentStart'
        additionalContext = 'SUPPORT DEMO POLICY (inherited): investigate the ticket using only [MASKED-EMAIL] placeholders. Do not restore raw customer contact data, and keep all hand-offs sanitized.'
    }
}