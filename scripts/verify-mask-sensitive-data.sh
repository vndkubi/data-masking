#!/usr/bin/env bash
# =============================================================
# verify-mask-sensitive-data.sh
# Verifies that mask-sensitive-data.sh correctly masks a file.
# Feeds the file content through the hook script as a
# UserPromptSubmit event and prints the masked output.
#
# Usage:
#   ./verify-mask-sensitive-data.sh <file_path>
#   ./verify-mask-sensitive-data.sh D:\path\to\file.json
#   ./verify-mask-sensitive-data.sh /mnt/d/path/to/file.json
# =============================================================
set -euo pipefail

# ------------------------------------------------------------------
# Colors
# ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ------------------------------------------------------------------
# Dependency check
# ------------------------------------------------------------------
if ! command -v jq &>/dev/null; then
    printf "${RED}ERROR:${RESET} jq is required.\n"
    printf "  Ubuntu/WSL: sudo apt-get install -y jq\n"
    printf "  macOS:      brew install jq\n"
    exit 1
fi

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------
to_unix_path() {
    local p="$1"
    if [[ "$p" =~ ^[A-Za-z]:[/\\] ]]; then
        if command -v wslpath &>/dev/null; then
            p=$(wslpath "$p" 2>/dev/null) || true
        else
            local drive="${p:0:1}"
            local rest="${p:2}"
            drive=$(printf '%s' "$drive" | tr '[:upper:]' '[:lower:]')
            rest="${rest//\\//}"
            p="/${drive}${rest}"
        fi
    fi
    printf '%s' "$p"
}

# Walk up directory tree to find project root (contains .github/hooks/masking-config.json)
find_project_root() {
    local dir="$1"
    while true; do
        if [ -f "$dir/.github/hooks/masking-config.json" ]; then
            printf '%s' "$dir"
            return 0
        fi
        local parent
        parent="$(dirname "$dir")"
        if [ "$parent" = "$dir" ]; then
            break
        fi
        dir="$parent"
    done
    return 1
}

# ------------------------------------------------------------------
# Args
# ------------------------------------------------------------------
if [ $# -eq 0 ]; then
    printf "${BOLD}Usage:${RESET} $0 <file_path>\n"
    printf "Example: $0 D:\\\\Personal\\\\Projects\\\\mask-data\\\\data\\\\0123456789123456.json\n"
    exit 1
fi

FILE_PATH=$(to_unix_path "$1")

if [ ! -f "$FILE_PATH" ]; then
    printf "${RED}ERROR:${RESET} File not found: %s\n" "$FILE_PATH"
    exit 1
fi

# ------------------------------------------------------------------
# Locate project root and hook script
# ------------------------------------------------------------------
FILE_DIR="$(cd "$(dirname "$FILE_PATH")" && pwd)"
SCRIPT_OWN_DIR="$(cd "$(dirname "$0")" && pwd)"

PROJECT_ROOT=""
# Try from the file's location first
if PROJECT_ROOT=$(find_project_root "$FILE_DIR" 2>/dev/null); then
    :
# Then try from this script's parent directory
elif PROJECT_ROOT=$(find_project_root "$(dirname "$SCRIPT_OWN_DIR")" 2>/dev/null); then
    :
else
    printf "${RED}ERROR:${RESET} Could not find .github/hooks/masking-config.json.\n"
    printf "Run this script from within the project that has the masking config.\n"
    exit 1
fi

HOOK_SCRIPT="$PROJECT_ROOT/.github/hooks/scripts/mask-sensitive-data.sh"

if [ ! -f "$HOOK_SCRIPT" ]; then
    printf "${RED}ERROR:${RESET} Hook script not found: %s\n" "$HOOK_SCRIPT"
    exit 1
fi

# ------------------------------------------------------------------
# Read file content
# ------------------------------------------------------------------
ORIGINAL=$(cat "$FILE_PATH")

# ------------------------------------------------------------------
# Build synthetic UserPromptSubmit hook payload
# ------------------------------------------------------------------
HOOK_PAYLOAD=$(jq -n \
    --arg prompt "$ORIGINAL" \
    --arg cwd    "$PROJECT_ROOT" \
    '{
        "hook_event_name": "UserPromptSubmit",
        "prompt": $prompt,
        "cwd":    $cwd
    }')

# ------------------------------------------------------------------
# Run the hook script
# ------------------------------------------------------------------
HOOK_OUTPUT=$(printf '%s' "$HOOK_PAYLOAD" | bash "$HOOK_SCRIPT" 2>/dev/null || true)

# ------------------------------------------------------------------
# Parse result
# ------------------------------------------------------------------
MASKED=$(printf '%s' "$HOOK_OUTPUT" | jq -r '.hookSpecificOutput.updatedInput.prompt // empty' 2>/dev/null || true)

# ------------------------------------------------------------------
# Display
# ------------------------------------------------------------------
printf "\n${BOLD}${CYAN}=== File: %s ===${RESET}\n\n" "$FILE_PATH"

printf "${BOLD}--- Original ---${RESET}\n"
printf '%s\n' "$ORIGINAL"
printf "\n"

if [ -n "$MASKED" ]; then
    printf "${BOLD}${GREEN}--- Masked (sensitive data replaced) ---${RESET}\n"
    printf '%s\n' "$MASKED"
    printf "\n"

    printf "${BOLD}${YELLOW}--- Diff (original vs masked) ---${RESET}\n"
    diff \
        <(printf '%s\n' "$ORIGINAL") \
        <(printf '%s\n' "$MASKED") \
        || true
    printf "\n"
    printf "${GREEN}PASS${RESET} — Sensitive data was detected and masked.\n\n"
else
    printf "${BOLD}--- Result ---${RESET}\n"
    printf "${YELLOW}No sensitive data detected.${RESET} Content would be passed through unchanged.\n\n"
fi
