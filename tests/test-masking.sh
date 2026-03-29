#!/usr/bin/env bash
# =============================================================
# test-masking.sh
# Cross-platform test runner for mask-sensitive-data.sh
# Works on: Linux, macOS, WSL, Git Bash (Windows)
#
# Usage:
#   bash tests/test-masking.sh
#   bash tests/test-masking.sh tests/fixtures/test-credit-card-bin.json
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
DIM='\033[2m'
RESET='\033[0m'

# On Windows cmd (non-ANSI) disable colors
if [ "${NO_COLOR:-}" = "1" ] || [ "${TERM:-}" = "dumb" ]; then
  RED="" GREEN="" YELLOW="" CYAN="" BOLD="" DIM="" RESET=""
fi

# ------------------------------------------------------------------
# Locate project
# ------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Cross-platform path helper
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

PROJECT_ROOT="$(to_unix_path "$PROJECT_ROOT")"
HOOK_SCRIPT="$PROJECT_ROOT/.github/hooks/scripts/mask-sensitive-data.sh"
CONFIG_PATH="$PROJECT_ROOT/.github/hooks/masking-config.json"
FIXTURE_DIR="$PROJECT_ROOT/tests/fixtures"

# ------------------------------------------------------------------
# Dependency check
# ------------------------------------------------------------------
MISSING=""
command -v jq    &>/dev/null || MISSING="${MISSING}jq "
command -v bash  &>/dev/null || MISSING="${MISSING}bash "
if [ -n "$MISSING" ]; then
  printf "${RED}ERROR: Missing required tools: ${MISSING}${RESET}\n"
  printf "  Ubuntu/WSL : sudo apt-get install -y jq\n"
  printf "  macOS      : brew install jq\n"
  printf "  Windows    : winget install jqlang.jq  OR  choco install jq\n"
  exit 1
fi

if [ ! -f "$HOOK_SCRIPT" ]; then
  printf "${RED}ERROR: Hook script not found: %s${RESET}\n" "$HOOK_SCRIPT"
  exit 1
fi

# ------------------------------------------------------------------
# Test engine
# ------------------------------------------------------------------
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0

run_mask_hook() {
  local input_text="$1"
  local payload
  payload=$(jq -n \
    --arg prompt "$input_text" \
    --arg cwd "$PROJECT_ROOT" \
    '{
      "hook_event_name": "UserPromptSubmit",
      "prompt": $prompt,
      "cwd": $cwd
    }')
  local output
  output=$(printf '%s' "$payload" | bash "$HOOK_SCRIPT" 2>/dev/null || true)

  local masked
  masked=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.updatedInput.prompt // empty' 2>/dev/null || true)
  printf '%s' "$masked"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]]
}

run_test_case() {
  local test_id="$1"
  local test_name="$2"
  local input="$3"
  local expect_masked="$4"
  local expect_output="$5"
  local expect_contains="$6"
  local expect_also_contains="$7"
  local note="$8"

  TOTAL=$((TOTAL + 1))

  # Run the hook
  local result
  result=$(run_mask_hook "$input")

  local status="PASS"
  local detail=""

  if [ "$expect_masked" = "true" ]; then
    if [ -z "$result" ]; then
      status="FAIL"
      detail="Expected masking but output was empty (no masking occurred)"
    elif [ -n "$expect_output" ] && [ "$result" != "$expect_output" ]; then
      status="FAIL"
      detail="Expected: '$expect_output', Got: '$result'"
    elif [ -n "$expect_contains" ] && ! assert_contains "$result" "$expect_contains"; then
      status="FAIL"
      detail="Expected to contain '$expect_contains', Got: '$result'"
    fi

    # Check expect_also_contains (JSON array as comma-separated)
    if [ "$status" = "PASS" ] && [ -n "$expect_also_contains" ] && [ "$expect_also_contains" != "null" ]; then
      local also_item
      for also_item in $(echo "$expect_also_contains" | jq -r '.[]?' 2>/dev/null || true); do
        if [ -n "$also_item" ] && ! assert_contains "$result" "$also_item"; then
          status="FAIL"
          detail="Expected to also contain '$also_item', Got: '$result'"
          break
        fi
      done
    fi

  elif [ "$expect_masked" = "false" ]; then
    if [ -n "$result" ]; then
      status="FAIL"
      detail="Expected NO masking but got: '$result'"
    fi
  else
    # expect_masked is not true/false (e.g. noted as "generic-fallback")
    # Just report what happened
    if [ -n "$result" ]; then
      detail="(info) Masked by other pattern: '$result'"
    else
      detail="(info) No masking occurred"
    fi
    status="INFO"
    SKIPPED=$((SKIPPED + 1))
  fi

  # Print result
  case "$status" in
    PASS)
      printf "  ${GREEN}✓ PASS${RESET} ${DIM}[%s]${RESET} %s\n" "$test_id" "$test_name"
      PASSED=$((PASSED + 1))
      ;;
    FAIL)
      printf "  ${RED}✗ FAIL${RESET} ${DIM}[%s]${RESET} %s\n" "$test_id" "$test_name"
      printf "         ${RED}%s${RESET}\n" "$detail"
      if [ -n "$note" ] && [ "$note" != "null" ]; then
        printf "         ${DIM}Note: %s${RESET}\n" "$note"
      fi
      FAILED=$((FAILED + 1))
      ;;
    INFO)
      printf "  ${YELLOW}○ INFO${RESET} ${DIM}[%s]${RESET} %s\n" "$test_id" "$test_name"
      printf "         ${DIM}%s${RESET}\n" "$detail"
      ;;
  esac
}

run_fixture_file() {
  local fixture_file="$1"
  local filename
  filename=$(basename "$fixture_file")

  printf "\n${BOLD}${CYAN}━━━ %s ━━━${RESET}\n" "$filename"

  local desc
  desc=$(jq -r '._description // ""' "$fixture_file" 2>/dev/null || true)
  if [ -n "$desc" ]; then
    printf "  ${DIM}%s${RESET}\n" "$desc"
  fi

  local case_count
  case_count=$(jq '.cases | length' "$fixture_file" 2>/dev/null || echo 0)

  for i in $(seq 0 $((case_count - 1))); do
    local test_id test_name input expect_masked expect_output expect_contains expect_also note
    test_id=$(jq -r ".cases[$i].id // \"TEST-$i\"" "$fixture_file")
    test_name=$(jq -r ".cases[$i].name // \"Unnamed\"" "$fixture_file")
    input=$(jq -r ".cases[$i].input // \"\"" "$fixture_file")
    expect_masked=$(jq -r ".cases[$i].expect_masked // \"unknown\"" "$fixture_file")
    expect_output=$(jq -r ".cases[$i].expect_output // \"\"" "$fixture_file")
    expect_contains=$(jq -r ".cases[$i].expect_contains // \"\"" "$fixture_file")
    expect_also=$(jq -c ".cases[$i].expect_also_contains // null" "$fixture_file")
    note=$(jq -r ".cases[$i].note // \"\"" "$fixture_file")

    run_test_case "$test_id" "$test_name" "$input" "$expect_masked" "$expect_output" "$expect_contains" "$expect_also" "$note"
  done
}

# ------------------------------------------------------------------
# Detect platform
# ------------------------------------------------------------------
detect_platform() {
  local os_name
  os_name="$(uname -s 2>/dev/null || echo "Unknown")"
  case "$os_name" in
    Linux*)
      if grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
        echo "WSL"
      else
        echo "Linux"
      fi
      ;;
    Darwin*)  echo "macOS"  ;;
    CYGWIN*)  echo "Cygwin" ;;
    MINGW*|MSYS*) echo "Git Bash (Windows)" ;;
    *)        echo "$os_name" ;;
  esac
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------
PLATFORM=$(detect_platform)
printf "${BOLD}╔═══════════════════════════════════════════════╗${RESET}\n"
printf "${BOLD}║   Sensitive Data Masking — Test Runner        ║${RESET}\n"
printf "${BOLD}╚═══════════════════════════════════════════════╝${RESET}\n"
printf "  Platform : ${CYAN}%s${RESET}\n" "$PLATFORM"
printf "  Shell    : ${CYAN}%s${RESET}\n" "$BASH_VERSION"
printf "  jq       : ${CYAN}%s${RESET}\n" "$(jq --version 2>/dev/null || echo 'unknown')"
printf "  Config   : ${DIM}%s${RESET}\n" "$CONFIG_PATH"

# Determine which fixtures to run
if [ $# -gt 0 ]; then
  FIXTURES=("$@")
else
  FIXTURES=()
  for f in "$FIXTURE_DIR"/test-*.json; do
    [ -f "$f" ] && FIXTURES+=("$f")
  done
fi

if [ ${#FIXTURES[@]} -eq 0 ]; then
  printf "\n${YELLOW}No test fixtures found in %s${RESET}\n" "$FIXTURE_DIR"
  exit 1
fi

for fixture in "${FIXTURES[@]}"; do
  fixture="$(to_unix_path "$fixture")"
  if [ ! -f "$fixture" ]; then
    printf "\n${RED}Fixture not found: %s${RESET}\n" "$fixture"
    continue
  fi
  run_fixture_file "$fixture"
done

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
printf "\n${BOLD}━━━ Summary ━━━${RESET}\n"
printf "  Total : %d\n" "$TOTAL"
printf "  ${GREEN}Passed: %d${RESET}\n" "$PASSED"
printf "  ${RED}Failed: %d${RESET}\n" "$FAILED"
if [ "$SKIPPED" -gt 0 ]; then
  printf "  ${YELLOW}Info  : %d${RESET}\n" "$SKIPPED"
fi

if [ "$FAILED" -gt 0 ]; then
  printf "\n${RED}${BOLD}SOME TESTS FAILED${RESET}\n\n"
  exit 1
else
  printf "\n${GREEN}${BOLD}ALL TESTS PASSED${RESET}\n\n"
  exit 0
fi
