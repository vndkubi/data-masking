#Requires -Version 5.1

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'HookDemoCommon.ps1')

$rawInput = Read-DemoRawInput
if ([string]::IsNullOrWhiteSpace($rawInput)) { exit 0 }
$hookData = Initialize-DemoContext -RawInput $rawInput
if (-not $hookData -or (Get-DemoHookEventName -HookData $hookData) -ne 'UserPromptSubmit') { exit 0 }

$prompt = if ($hookData.prompt) { $hookData.prompt } else { $null }
if ($prompt -and (Test-DemoSensitive $prompt)) {
    $maskedPrompt = Invoke-DemoMask $prompt
    Write-DemoAudit 'UserPromptSubmit' 'Customer contact masked before support prompt execution'
    Write-DemoJsonOutput @{
        hookSpecificOutput = @{
            hookEventName = 'UserPromptSubmit'
            permissionDecision = 'allow'
            permissionDecisionReason = 'Customer contact data masked for the support escalation demo'
            updatedInput = @{ prompt = $maskedPrompt }
            systemMessage = "The customer's contact data was masked before the prompt entered the support workflow."
        }
    }
}