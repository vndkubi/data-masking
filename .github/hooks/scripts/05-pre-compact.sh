#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/hook-demo-common.sh"
trap 'demo_cleanup' EXIT

INPUT="$(demo_read_input)"
[ -z "$INPUT" ] && exit 0
demo_init_context "$INPUT" || exit 0
[ "$DEMO_HOOK_EVENT" != "PreCompact" ] && exit 0

demo_audit "PreCompact" "Support escalation summary prepared for compacted context"
jq -n '{"systemMessage":"Support demo reminder: compact only masked ticket notes, masked customer contacts, and safe action summaries."}'