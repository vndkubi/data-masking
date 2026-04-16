#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/hook-demo-common.sh"
trap 'demo_cleanup' EXIT

INPUT="$(demo_read_input)"
[ -z "$INPUT" ] && exit 0
demo_init_context "$INPUT" || exit 0
[ "$DEMO_HOOK_EVENT" != "UserPromptSubmit" ] && exit 0

PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || true)
[ -z "$PROMPT" ] && exit 0

if demo_has_sensitive "$PROMPT"; then
	MASKED_PROMPT=$(demo_mask_sensitive "$PROMPT")
	demo_audit "UserPromptSubmit" "Customer contact masked before support prompt execution"
	jq -n --arg prompt "$MASKED_PROMPT" --arg message "The customer's contact data was masked before the prompt entered the support workflow." '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","permissionDecision":"allow","permissionDecisionReason":"Customer contact data masked for the support escalation demo","updatedInput":{"prompt":$prompt},"systemMessage":$message}}'
fi