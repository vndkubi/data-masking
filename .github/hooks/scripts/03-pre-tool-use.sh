#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/hook-demo-common.sh"
trap 'demo_cleanup' EXIT

INPUT="$(demo_read_input)"
[ -z "$INPUT" ] && exit 0
demo_init_context "$INPUT" || exit 0
[ "$DEMO_HOOK_EVENT" != "PreToolUse" ] && exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // .toolName // "unknown"' 2>/dev/null || printf 'unknown')
TOOL_INPUT_JSON=$(printf '%s' "$INPUT" | jq -c '.tool_input // .toolInput // .input // .toolArgs // {}' 2>/dev/null || printf '{}')
MASKED_INPUT=$(demo_mask_sensitive "$TOOL_INPUT_JSON")
UPDATED_INPUT=$(printf '%s' "$MASKED_INPUT" | jq '.' 2>/dev/null || printf '%s' "$MASKED_INPUT")
LOG_PATH="$(demo_write_state_log "$INPUT" "Captured PreToolUse payload for tool '$TOOL_NAME'")"
demo_audit "PreToolUse" "Logged PreToolUse payload for $TOOL_NAME to $LOG_PATH"
jq -n --argjson updated "$UPDATED_INPUT" --arg reason "Demo trace saved for PreToolUse (tool: $TOOL_NAME)" --arg context "PreToolUse payload was logged to $LOG_PATH. Use the log file to explain what the hook receives before '$TOOL_NAME' runs." '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":$reason,"updatedInput":$updated,"additionalContext":$context}}'