#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/hook-demo-common.sh"
trap 'demo_cleanup' EXIT

INPUT="$(demo_read_input)"
[ -z "$INPUT" ] && exit 0
demo_init_context "$INPUT" || exit 0
[ "$DEMO_HOOK_EVENT" != "SessionStart" ] && exit 0

demo_audit "SessionStart" "Support escalation demo initialized"

jq -n --arg context "SCENARIO ACTIVE - CUSTOMER SUPPORT ESCALATION DEMO:\nYou are assisting an internal support agent who must handle customer tickets without exposing raw contact data.\n\nDemo goals:\n1. Mask customer emails in prompts before the model uses them.\n2. Sanitize internal tool commands before execution.\n3. Block raw ticket reads and return a safe snapshot instead.\n4. Ask for confirmation before any external lookup involving customer contact data.\n5. Keep summaries and sub-agent hand-offs fully sanitized.\n\nRules:\n- Use [MASKED-EMAIL] whenever customer contact data is referenced.\n- Never reconstruct the original values.\n- Pass only masked values to tools, APIs, and sub-agents.\n- Treat numeric filenames with 9-16 digits as [MASKED-FILENAME]." '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":$context}}'