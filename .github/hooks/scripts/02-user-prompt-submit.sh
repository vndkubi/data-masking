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
MASKED_PROMPT=$(demo_mask_sensitive "$PROMPT")
LOG_PATH="$(demo_write_state_log "$INPUT" "Captured UserPromptSubmit payload for demo")"
demo_audit "UserPromptSubmit" "Logged UserPromptSubmit payload to $LOG_PATH"
jq -n --arg prompt "$MASKED_PROMPT" --arg message "UserPromptSubmit payload was logged to $LOG_PATH. Use the log file to show the sanitized prompt." '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","permissionDecision":"allow","permissionDecisionReason":"Demo trace saved for UserPromptSubmit","updatedInput":{"prompt":$prompt},"systemMessage":$message}}'