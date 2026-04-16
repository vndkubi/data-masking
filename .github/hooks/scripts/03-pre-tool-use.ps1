#Requires -Version 5.1

$ErrorActionPreference = "Stop"

# Resolve the first property that exists from a list of possible payload names.
# The hook payload can vary slightly between local test fixtures and live Copilot events,
# so the script accepts multiple aliases for the same logical field.
function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        $Object,
        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    foreach ($name in $Names) {
        if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $name) {
            return $Object.$name
        }
    }

    return $null
}

# Build the JSON object returned to Copilot.
# `permissionDecision` controls whether the tool call proceeds,
# `permissionDecisionReason` explains the policy result,
# and `updatedInput` is only included when the hook rewrites arguments.
function New-HookResponse {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Decision,
        [Parameter(Mandatory = $true)]
        [string]$Reason,
        $UpdatedInput = $null,
        [string]$AdditionalContext = ""
    )

    $hookOutput = [ordered]@{
        hookEventName = "PreToolUse"
        permissionDecision = $Decision
        permissionDecisionReason = $Reason
    }

    if ($null -ne $UpdatedInput) {
        $hookOutput.updatedInput = $UpdatedInput
    }

    if (-not [string]::IsNullOrWhiteSpace($AdditionalContext)) {
        $hookOutput.additionalContext = $AdditionalContext
    }

    return @{ hookSpecificOutput = $hookOutput }
}

# Copilot sends the hook payload through STDIN.
# If nothing was piped in, there is nothing to inspect and the script exits quietly.
$rawInput = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($rawInput)) {
    exit 0
}

# Parse the incoming hook payload and ensure this script only reacts to PreToolUse.
# That makes local testing safer and prevents accidental reuse on other events.
$payload = $rawInput | ConvertFrom-Json
$hookEvent = Get-PropertyValue -Object $payload -Names @("hook_event_name", "hookEventName")
if (-not [string]::IsNullOrWhiteSpace($hookEvent) -and $hookEvent -ne "PreToolUse") {
    exit 0
}

# Pull the tool arguments out of the payload. Different fixtures may use
# `tool_input`, `toolInput`, `input`, or `toolArgs`, so the script checks all of them.
$toolInput = Get-PropertyValue -Object $payload -Names @("tool_input", "toolInput", "input", "toolArgs")
if ($null -eq $toolInput) {
    $toolInput = [pscustomobject]@{}
}

# The demo policy is centered on an `email` argument.
# If it is missing, the tool call is denied immediately with a readable message.
$email = [string](Get-PropertyValue -Object $toolInput -Names @("email"))
if ([string]::IsNullOrWhiteSpace($email)) {
    $response = New-HookResponse -Decision "deny" -Reason "Action blocked! Email is required before this tool can run."
    $response | ConvertTo-Json -Depth 20 -Compress
    exit 0
}

# Normalize the email before checking policy rules so validation is stable.
# In practice this trims accidental spaces from forms and lowercases the address.
$normalizedEmail = $email.Trim().ToLowerInvariant()
$domain = if ($normalizedEmail.Contains("@")) { $normalizedEmail.Split("@")[-1] } else { "" }
$blockedDomains = @("blocked.example", "disposable.example")

# First rule: reject malformed addresses.
# This catches obviously invalid values before the script considers domain allow/block rules.
if ($normalizedEmail -notmatch '^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$') {
    $response = New-HookResponse -Decision "deny" -Reason "Action blocked! '$email' is not a valid email address."
    $response | ConvertTo-Json -Depth 20 -Compress
    exit 0
}

# Second rule: deny known blocked domains.
# Returning `deny` here is the Copilot hook equivalent of `allowed: false`.
if ($blockedDomains -contains $domain) {
    $response = New-HookResponse -Decision "deny" -Reason "Action blocked! Email domain '$domain' is not allowed."
    $response | ConvertTo-Json -Depth 20 -Compress
    exit 0
}

# At this point the email passed validation, so update the input object with the normalized value.
# This is what demonstrates the screenshot's `modifiedArgs` behavior.
if ($toolInput.PSObject.Properties.Name -contains "email") {
    $toolInput.email = $normalizedEmail
}

# If normalization changed the original text, allow the tool call and return `updatedInput`.
# Copilot can then continue execution using the cleaned argument list.
if ($normalizedEmail -ne $email) {
    $response = New-HookResponse `
        -Decision "allow" `
        -Reason "Email input normalized before execution." `
        -UpdatedInput $toolInput `
        -AdditionalContext "The hook trimmed whitespace and lowercased the email value."
    $response | ConvertTo-Json -Depth 20 -Compress
    exit 0
}

# Otherwise the incoming email was already valid, so the hook simply allows the call
# and echoes the unchanged arguments back for demo clarity.
$response = New-HookResponse `
    -Decision "allow" `
    -Reason "Email input allowed." `
    -UpdatedInput $toolInput `
    -AdditionalContext "The email already satisfied the policy. No changes were required."
$response | ConvertTo-Json -Depth 20 -Compress