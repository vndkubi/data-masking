#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/hook-demo-common.sh"
trap 'demo_cleanup' EXIT

INPUT="$(demo_read_input)"
[ -z "$INPUT" ] && exit 0
demo_init_context "$INPUT" || exit 0
[ "$DEMO_HOOK_EVENT" != "SubagentStart" ] && exit 0

AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.agent_type // "unknown"' 2>/dev/null || printf 'unknown')
LOG_PATH="$(demo_write_state_log "$INPUT" "Captured SubagentStart payload for agent '$AGENT_TYPE'")"
demo_audit "SubagentStart" "Logged SubagentStart payload for $AGENT_TYPE to $LOG_PATH"
jq -n --arg context "SubagentStart payload was logged to $LOG_PATH for agent '$AGENT_TYPE'. Use it to explain what context is passed to sub-agents." '{"hookSpecificOutput":{"hookEventName":"SubagentStart","additionalContext":$context}}'