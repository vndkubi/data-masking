#Requires -Version 5.1

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'HookDemoCommon.ps1')

$rawInput = Read-DemoRawInput
if ([string]::IsNullOrWhiteSpace($rawInput)) { exit 0 }
$hookData = Initialize-DemoContext -RawInput $rawInput
if (-not $hookData -or (Get-DemoHookEventName -HookData $hookData) -ne 'SessionStart') { exit 0 }

Write-DemoAudit 'SessionStart' 'Support escalation demo initialized'
Write-DemoJsonOutput @{
    hookSpecificOutput = @{
        hookEventName = 'SessionStart'
        additionalContext = "SCENARIO ACTIVE - CUSTOMER SUPPORT ESCALATION DEMO:`nYou are assisting an internal support agent who must handle customer tickets without exposing raw contact data.`n`nDemo goals:`n1. Mask customer emails in prompts before the model uses them.`n2. Sanitize internal tool commands before execution.`n3. Block raw ticket reads and return a safe snapshot instead.`n4. Ask for confirmation before any external lookup involving customer contact data.`n5. Keep summaries and sub-agent hand-offs fully sanitized.`n`nRules:`n- Use [MASKED-EMAIL] whenever customer contact data is referenced.`n- Never reconstruct the original values.`n- Pass only masked values to tools, APIs, and sub-agents.`n- Treat numeric filenames with 9-16 digits as [MASKED-FILENAME]."
    }
}