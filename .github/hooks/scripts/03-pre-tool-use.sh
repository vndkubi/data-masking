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

if [ "$TOOL_NAME" = "read_file" ] || [ "$TOOL_NAME" = "readFile" ]; then
	FILE_PATH=$(printf '%s' "$TOOL_INPUT_JSON" | jq -r '.filePath // .file_path // .path // empty' 2>/dev/null || true)
	if [ -n "$FILE_PATH" ]; then
		RESOLVED_PATH=$(demo_resolve_file_path "$FILE_PATH")
		if [ -f "$RESOLVED_PATH" ]; then
			FILE_CONTENT=$(cat "$RESOLVED_PATH" 2>/dev/null || true)
			if [ -n "$FILE_CONTENT" ] && demo_has_sensitive "$FILE_CONTENT"; then
				MASKED_CONTENT=$(demo_mask_sensitive "$FILE_CONTENT")
				demo_audit "PreToolUse" "Returned sanitized ticket snapshot for read_file"
				jq -n --arg reason "SUPPORT DEMO: Raw ticket content contains customer contact data. Use this sanitized ticket snapshot instead:\n$MASKED_CONTENT\nOnly quote the sanitized snapshot in your response." '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
				exit 0
			fi
		fi
	fi
fi

if printf '%s' "$TOOL_NAME" | grep -qiE "$DEMO_EXTERNAL_TOOLS_REGEX" 2>/dev/null && demo_has_sensitive "$TOOL_INPUT_JSON"; then
	demo_audit "PreToolUse" "External support lookup paused for confirmation"
	jq -n --arg tool "$TOOL_NAME" --arg reason "Support demo safeguard: the external lookup '$tool' includes customer contact data. Confirm that you want to send it, or mask it first." '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":$reason}}'
	exit 0
fi

if demo_has_sensitive "$TOOL_INPUT_JSON"; then
	MASKED_INPUT=$(demo_mask_sensitive "$TOOL_INPUT_JSON")
	UPDATED_INPUT=$(printf '%s' "$MASKED_INPUT" | jq '.' 2>/dev/null || printf '%s' "$MASKED_INPUT")
	demo_audit "PreToolUse" "Internal support action sanitized before tool execution"
	jq -n --argjson updated "$UPDATED_INPUT" --arg context "The support workflow may continue, but only with masked customer contact data." '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Support action sanitized before tool execution","updatedInput":$updated,"additionalContext":$context}}'
fi