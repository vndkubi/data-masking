#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/hook-demo-common.sh"
trap 'demo_cleanup' EXIT

INPUT="$(demo_read_input)"
[ -z "$INPUT" ] && exit 0
demo_init_context "$INPUT" || exit 0
[ "$DEMO_HOOK_EVENT" != "PostToolUse" ] && exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // .toolName // "unknown"' 2>/dev/null || printf 'unknown')
TOOL_RESPONSE=$(printf '%s' "$INPUT" | jq -c '.tool_response // .toolResponse // .output // empty' 2>/dev/null || true)
MASKED_RESPONSE=$(demo_mask_sensitive "$TOOL_RESPONSE")
LOG_PATH="$(demo_write_state_log "$INPUT" "Captured PostToolUse payload for tool '$TOOL_NAME'")"
demo_audit "PostToolUse" "Logged PostToolUse payload for $TOOL_NAME to $LOG_PATH"
jq -n --arg context "PostToolUse payload was logged to $LOG_PATH. Sanitized response preview:\n$MASKED_RESPONSE" '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":$context}}'