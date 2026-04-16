#!/usr/bin/env bash
# =============================================================
# verify-hook-demo.sh
# Verifies that the UserPromptSubmit demo hook correctly masks a file.
# Feeds the file content through the hook script as a
# UserPromptSubmit event and prints the masked output.
#
# Usage:
#   ./verify-hook-demo.sh <file_path>
#   ./verify-hook-demo.sh D:\path\to\file.json
#   ./verify-hook-demo.sh /mnt/d/path/to/file.json
# =============================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

to_unix_path() {
    local p="$1"
    if [[ "$p" =~ ^[A-Za-z]:[/\\] ]]; then
        local drive="${p:0:1}"
        local rest="${p:2}"
        drive=$(printf '%s' "$drive" | tr '[:upper:]' '[:lower:]')
        rest="${rest//\\//}"
        p="/${drive}${rest}"
    fi
    printf '%s' "$p"
}

find_project_root() {
    local start_dir="$1"
    local dir="$start_dir"
    while [ "$dir" != "/" ] && [ -n "$dir" ]; do
        if [ -f "$dir/.github/hooks/masking-config.json" ]; then
            printf '%s' "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

if [ $# -eq 0 ]; then
    printf "${BOLD}Usage:${RESET} $0 <file_path>\n"
    printf "Example: $0 D:\\Personal\\Projects\\mask-data\\data\\data-sample.json\n"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    printf "${RED}ERROR:${RESET} jq is required but not installed.\n"
    exit 1
fi

INPUT_PATH_RAW="$1"
INPUT_PATH="$(to_unix_path "$INPUT_PATH_RAW")"

if [ ! -f "$INPUT_PATH" ]; then
    printf "${RED}ERROR:${RESET} File not found: %s\n" "$INPUT_PATH_RAW"
    exit 1
fi

ABS_INPUT_PATH="$(cd "$(dirname "$INPUT_PATH")" && pwd)/$(basename "$INPUT_PATH")"
PROJECT_ROOT="$(find_project_root "$(dirname "$ABS_INPUT_PATH")")" || {
    printf "${RED}ERROR:${RESET} Could not locate project root from: %s\n" "$INPUT_PATH_RAW"
    exit 1
}

HOOK_SCRIPT="$PROJECT_ROOT/.github/hooks/scripts/02-user-prompt-submit.sh"

if [ ! -f "$HOOK_SCRIPT" ]; then
    printf "${RED}ERROR:${RESET} Hook script not found: %s\n" "$HOOK_SCRIPT"
    exit 1
fi

FILE_CONTENT="$(cat "$ABS_INPUT_PATH")"

HOOK_PAYLOAD=$(jq -n \
    --arg prompt "$FILE_CONTENT" \
    --arg cwd "$PROJECT_ROOT" \
    '{
      hook_event_name: "UserPromptSubmit",
      prompt: $prompt,
      cwd: $cwd
    }')

HOOK_OUTPUT="$(printf '%s' "$HOOK_PAYLOAD" | bash "$HOOK_SCRIPT")"

MASKED_PROMPT=$(printf '%s' "$HOOK_OUTPUT" | jq -r '.hookSpecificOutput.updatedInput.prompt // empty')

printf "${CYAN}${BOLD}Input file:${RESET} %s\n" "$INPUT_PATH_RAW"
printf "${CYAN}${BOLD}Hook script:${RESET} %s\n\n" "$HOOK_SCRIPT"

printf "${YELLOW}${BOLD}Original content:${RESET}\n"
printf '%s\n\n' "$FILE_CONTENT"

if [ -n "$MASKED_PROMPT" ]; then
    printf "${GREEN}${BOLD}Masked content:${RESET}\n"
    printf '%s\n' "$MASKED_PROMPT"
else
    printf "${YELLOW}No masking output was returned by the hook.${RESET}\n"
fi