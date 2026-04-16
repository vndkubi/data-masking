#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$SCRIPT_DIR/../run-hook-demo.sh" "$SCRIPT_DIR/../../demo/hooks/04-pre-tool-use-read-file"