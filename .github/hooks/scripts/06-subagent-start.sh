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
demo_audit "SubagentStart" "Delegated sanitized support task to $AGENT_TYPE"
jq -n --arg context "SUPPORT DEMO POLICY (inherited): investigate the ticket using only [MASKED-EMAIL] placeholders. Do not restore raw customer contact data, and keep all hand-offs sanitized." '{"hookSpecificOutput":{"hookEventName":"SubagentStart","additionalContext":$context}}'