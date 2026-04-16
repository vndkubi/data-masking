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

if [ -n "$TOOL_RESPONSE" ] && demo_has_sensitive "$TOOL_RESPONSE"; then
	MASKED_RESPONSE=$(demo_mask_sensitive "$TOOL_RESPONSE")
	demo_audit "PostToolUse" "External support lookup result sanitized"
	jq -n --arg tool "$TOOL_NAME" --arg context "SUPPORT DEMO ALERT: The tool '$tool' returned customer contact data. Reuse only this sanitized result:\n$MASKED_RESPONSE" '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":$context}}'
fi