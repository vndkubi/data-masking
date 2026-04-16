#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/hook-demo-common.sh"
trap 'demo_cleanup' EXIT

INPUT="$(demo_read_input)"
[ -z "$INPUT" ] && exit 0
demo_init_context "$INPUT" || exit 0
[ "$DEMO_HOOK_EVENT" != "PreCompact" ] && exit 0

LOG_PATH="$(demo_write_state_log "$INPUT" "Captured PreCompact payload for demo")"
demo_audit "PreCompact" "Logged PreCompact payload to $LOG_PATH"
jq -n --arg message "PreCompact payload was logged to $LOG_PATH. Use it to explain what Copilot sends before compaction." '{"systemMessage":$message}'