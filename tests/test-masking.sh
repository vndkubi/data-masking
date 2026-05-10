#!/usr/bin/env bash
# Runs the PowerShell fixture test on Linux, macOS, WSL, and devcontainers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_SCRIPT="$PROJECT_ROOT/tests/test-masking.ps1"

if ! command -v pwsh >/dev/null 2>&1; then
  printf 'ERROR: pwsh is required for Linux/macOS/WSL/devcontainer test runs.\n' >&2
  printf 'Install PowerShell 7 in the current environment, then rerun this script.\n' >&2
  exit 1
fi

if [ ! -f "$TEST_SCRIPT" ]; then
  printf 'ERROR: test script not found: %s\n' "$TEST_SCRIPT" >&2
  exit 1
fi

if [ $# -gt 0 ]; then
  exec pwsh -NoLogo -NoProfile -File "$TEST_SCRIPT" -FixturePath "$1"
fi

exec pwsh -NoLogo -NoProfile -File "$TEST_SCRIPT"
