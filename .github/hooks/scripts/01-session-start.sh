#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/hook-demo-common.sh"
trap 'demo_cleanup' EXIT

INPUT="$(demo_read_input)"
[ -z "$INPUT" ] && exit 0
demo_init_context "$INPUT" || exit 0
[ "$DEMO_HOOK_EVENT" != "SessionStart" ] && exit 0

LOG_PATH="$(demo_write_state_log "$INPUT" "Captured SessionStart payload for demo")"
demo_audit "SessionStart" "Logged SessionStart payload to $LOG_PATH"

jq -n --arg context "DEMO TRACE: SessionStart payload was logged to $LOG_PATH. Open the log file to see what Copilot sends when a session starts." '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":$context}}'