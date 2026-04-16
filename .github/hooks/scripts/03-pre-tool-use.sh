#!/usr/bin/env bash
set -euo pipefail

# Copilot sends the hook payload on STDIN. Read the full JSON body first,
# then exit quietly if the script was invoked without any input.
INPUT="$(cat)"
if [ -z "${INPUT//[[:space:]]/}" ]; then
  exit 0
fi

# Only act on PreToolUse payloads. This keeps the script safe to run in isolation
# and makes the control flow explicit during a demo.
HOOK_EVENT="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // .hookEventName // empty')"
if [ -n "$HOOK_EVENT" ] && [ "$HOOK_EVENT" != "PreToolUse" ]; then
  exit 0
fi

# Extract the tool arguments from whichever field name is present.
# The fallback chain lets the same script handle local fixtures and live hook payloads.
TOOL_INPUT_JSON="$(printf '%s' "$INPUT" | jq -c '.tool_input // .toolInput // .input // .toolArgs // {}')"
EMAIL="$(printf '%s' "$TOOL_INPUT_JSON" | jq -r '.email // empty')"

# The demo policy requires an email argument. Missing email means an immediate deny response.
if [ -z "$EMAIL" ]; then
  jq -n '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Action blocked! Email is required before this tool can run."}}'
  exit 0
fi

# Normalize before validation so extra spaces and uppercase letters do not create false negatives.
NORMALIZED_EMAIL="$(printf '%s' "$EMAIL" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"
DOMAIN="${NORMALIZED_EMAIL##*@}"

# First rule: reject malformed addresses.
# This is the hook version of `allowed: false` with a validation message.
if [[ ! "$NORMALIZED_EMAIL" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]]; then
  jq -n --arg reason "Action blocked! '$EMAIL' is not a valid email address." '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
  exit 0
fi

# Second rule: reject email domains that the demo treats as blocked by policy.
if [ "$DOMAIN" = "blocked.example" ] || [ "$DOMAIN" = "disposable.example" ]; then
  jq -n --arg reason "Action blocked! Email domain '$DOMAIN' is not allowed." '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
  exit 0
fi

# Update the JSON arguments with the normalized email.
# This corresponds to the screenshot's `modifiedArgs` case.
UPDATED_INPUT="$(printf '%s' "$TOOL_INPUT_JSON" | jq -c --arg email "$NORMALIZED_EMAIL" '.email = $email')"

# If normalization changed the value, allow the tool call and send the rewritten arguments back.
if [ "$NORMALIZED_EMAIL" != "$EMAIL" ]; then
  jq -n \
    --argjson updated "$UPDATED_INPUT" \
    --arg reason "Email input normalized before execution." \
    --arg context "The hook trimmed whitespace and lowercased the email value." \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":$reason,"updatedInput":$updated,"additionalContext":$context}}'
  exit 0
fi

# If nothing needed to change, allow the call as-is and return the unchanged arguments.
jq -n \
  --argjson updated "$UPDATED_INPUT" \
  --arg reason "Email input allowed." \
  --arg context "The email already satisfied the policy. No changes were required." \
  '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":$reason,"updatedInput":$updated,"additionalContext":$context}}'