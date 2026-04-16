#!/usr/bin/env bash
set -euo pipefail

INPUT_PATH="${1:-}"
EXPECTED_PATH="${2:-}"

if [ -z "$INPUT_PATH" ]; then
  echo "Usage: bash scripts/run-hook-demo.sh demo/hooks/01-allow-email [expected.json]" >&2
  exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -d "$INPUT_PATH" ]; then
  SCENARIO_PATH="$INPUT_PATH"
  INPUT_PATH="$SCENARIO_PATH/input.json"
  if [ -z "$EXPECTED_PATH" ]; then
    EXPECTED_PATH="$SCENARIO_PATH/expected.json"
  fi
fi

if [ ! -f "$INPUT_PATH" ]; then
  echo "Input file not found: $INPUT_PATH" >&2
  exit 1
fi

HOOK_SCRIPT="$PROJECT_ROOT/.github/hooks/scripts/03-pre-tool-use.sh"
if [ ! -f "$HOOK_SCRIPT" ]; then
  echo "Hook script not found: $HOOK_SCRIPT" >&2
  exit 1
fi

PAYLOAD_JSON="$(jq -c --arg cwd "$PROJECT_ROOT" '.cwd = $cwd' "$INPUT_PATH")"
ACTUAL_JSON="$(printf '%s' "$PAYLOAD_JSON" | bash "$HOOK_SCRIPT")"

if [ -z "${ACTUAL_JSON//[[:space:]]/}" ]; then
  echo "Hook returned no output." >&2
  exit 1
fi

printf '%s\n' "$ACTUAL_JSON" | jq '.'

if [ -n "$EXPECTED_PATH" ]; then
  if [ ! -f "$EXPECTED_PATH" ]; then
    echo "Expected file not found: $EXPECTED_PATH" >&2
    exit 1
  fi

  ACTUAL_NORMALIZED="$(printf '%s' "$ACTUAL_JSON" | jq -S '.')"
  EXPECTED_NORMALIZED="$(jq -S '.' "$EXPECTED_PATH")"

  if [ "$ACTUAL_NORMALIZED" != "$EXPECTED_NORMALIZED" ]; then
    echo "Actual output did not match expected output." >&2
    exit 1
  fi

  echo "Expected output matched."
fi