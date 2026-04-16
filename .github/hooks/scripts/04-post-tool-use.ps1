#Requires -Version 5.1

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'HookDemoCommon.ps1')

$rawInput = Read-DemoRawInput
if ([string]::IsNullOrWhiteSpace($rawInput)) { exit 0 }
$hookData = Initialize-DemoContext -RawInput $rawInput
if (-not $hookData -or (Get-DemoHookEventName -HookData $hookData) -ne 'PostToolUse') { exit 0 }

$toolName = Get-DemoToolName -HookData $hookData
$toolResponseObj = Get-DemoToolResponseObject -HookData $hookData
if ($null -ne $toolResponseObj) {
    $toolResponseJson = ConvertTo-DemoJsonString $toolResponseObj
    if (Test-DemoSensitive $toolResponseJson) {
        $maskedResponse = Invoke-DemoMask $toolResponseJson
        Write-DemoAudit 'PostToolUse' 'External support lookup result sanitized'
        Write-DemoJsonOutput @{
            hookSpecificOutput = @{
                hookEventName = 'PostToolUse'
                additionalContext = "SUPPORT DEMO ALERT: The tool '$toolName' returned customer contact data. Reuse only this sanitized result:`n$maskedResponse"
            }
        }
    }
}