#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  printf 'Usage: %s <scenario-dir|input-json> [expected-json]\n' "$0"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INPUT_PATH="$1"
EXPECTED_PATH="${2:-}"
HOOK_SCRIPT=""

if [ -d "$INPUT_PATH" ]; then
  SCENARIO_PATH="$INPUT_PATH"
  INPUT_PATH="$SCENARIO_PATH/input.json"
  if [ -z "$EXPECTED_PATH" ]; then
    EXPECTED_PATH="$SCENARIO_PATH/expected.json"
  fi
fi

if [ ! -f "$INPUT_PATH" ]; then
  printf 'Input file not found: %s\n' "$INPUT_PATH"
  exit 1
fi

HOOK_EVENT=$(jq -r '.hook_event_name // .hookEventName // empty' "$INPUT_PATH")
case "$HOOK_EVENT" in
  SessionStart) HOOK_SCRIPT="$PROJECT_ROOT/.github/hooks/scripts/01-session-start.sh" ;;
  UserPromptSubmit) HOOK_SCRIPT="$PROJECT_ROOT/.github/hooks/scripts/02-user-prompt-submit.sh" ;;
  PreToolUse) HOOK_SCRIPT="$PROJECT_ROOT/.github/hooks/scripts/03-pre-tool-use.sh" ;;
  PostToolUse) HOOK_SCRIPT="$PROJECT_ROOT/.github/hooks/scripts/04-post-tool-use.sh" ;;
  PreCompact) HOOK_SCRIPT="$PROJECT_ROOT/.github/hooks/scripts/05-pre-compact.sh" ;;
  SubagentStart) HOOK_SCRIPT="$PROJECT_ROOT/.github/hooks/scripts/06-subagent-start.sh" ;;
  *)
    printf 'Unsupported hook event in payload: %s\n' "$HOOK_EVENT"
    exit 1
    ;;
esac

if [ ! -f "$HOOK_SCRIPT" ]; then
  printf 'Hook script not found: %s\n' "$HOOK_SCRIPT"
  exit 1
fi

PAYLOAD=$(jq --arg cwd "$PROJECT_ROOT" '.cwd = $cwd' "$INPUT_PATH")
OUTPUT=$(printf '%s' "$PAYLOAD" | bash "$HOOK_SCRIPT" 2>/dev/null || true)

if [ -z "$OUTPUT" ]; then
  printf 'Hook returned no output.\n'
  exit 1
fi

printf '%s\n' "$OUTPUT" | jq '.'

if [ -n "$EXPECTED_PATH" ]; then
  if [ ! -f "$EXPECTED_PATH" ]; then
    printf 'Expected file not found: %s\n' "$EXPECTED_PATH"
    exit 1
  fi

  ACTUAL_SORTED=$(printf '%s' "$OUTPUT" | jq -S '.')
  EXPECTED_SORTED=$(jq -S '.' "$EXPECTED_PATH")

  if [ "$ACTUAL_SORTED" != "$EXPECTED_SORTED" ]; then
    diff \
      <(printf '%s\n' "$EXPECTED_SORTED") \
      <(printf '%s\n' "$ACTUAL_SORTED") \
      || true
    exit 1
  fi

  printf 'Expected output matched.\n'
fi