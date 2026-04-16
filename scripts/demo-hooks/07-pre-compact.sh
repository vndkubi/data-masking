#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$SCRIPT_DIR/../run-hook-demo.sh" "$SCRIPT_DIR/../../demo/hooks/07-pre-compact"