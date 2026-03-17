#!/usr/bin/env bash
# =============================================================
# invoke-restore.sh
# Restore original sensitive filenames after Copilot session.
#
# Usage:
#   ./invoke-restore.sh
#   ./invoke-restore.sh /path/to/project
# =============================================================
set -euo pipefail

WORKSPACE_ROOT="${1:-$(pwd)}"
WORKSPACE_ROOT="${WORKSPACE_ROOT%/}"
MAPPING_FILE="$WORKSPACE_ROOT/.github/hooks/.masked-files.json"

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------
log_green() { printf '\033[0;32m%s\033[0m\n' "$@"; }
log_yellow(){ printf '\033[0;33m%s\033[0m\n' "$@"; }
log_gray()  { printf '\033[0;90m%s\033[0m\n' "$@"; }
warn()      { printf '\033[0;33mWARN: %s\033[0m\n' "$@" >&2; }

# ------------------------------------------------------------------
# Check mapping
# ------------------------------------------------------------------
if [ ! -f "$MAPPING_FILE" ]; then
  log_yellow "[invoke-restore] No mapping file found. Nothing to restore."
  exit 0
fi

# ------------------------------------------------------------------
# Parse mapping with awk (no jq dependency)
# ------------------------------------------------------------------
parse_field() {
  local json="$1" field="$2"
  echo "$json" | grep -o "\"$field\":\"[^\"]*\"" | head -1 | sed "s/\"$field\":\"//;s/\"//"
}

# Extract file entries — each object on its own parsing pass
readarray -t FILE_BLOCKS < <(
  python3 -c "
import json, sys
data = json.load(open('$MAPPING_FILE'))
for f in data.get('files', []):
    print(f['maskedPath'] + '|' + f['originalName'] + '|' + f['originalPath'])
" 2>/dev/null || \
  # Fallback: awk-based parser (no python)
  awk '
    /maskedPath/   { match($0, /"maskedPath":"([^"]+)"/, a);   mp=a[1] }
    /originalName/ { match($0, /"originalName":"([^"]+)"/, a); on=a[1] }
    /originalPath/ { match($0, /"originalPath":"([^"]+)"/, a); op=a[1]
                     print mp "|" on "|" op; mp=""; on=""; op="" }
  ' "$MAPPING_FILE"
)

if [ ${#FILE_BLOCKS[@]} -eq 0 ]; then
  log_yellow "[invoke-restore] Mapping is empty. Nothing to restore."
  rm -f "$MAPPING_FILE"
  exit 0
fi

# ------------------------------------------------------------------
# Restore files
# ------------------------------------------------------------------
restored=0
failed=0
declare -a ORIG_PATHS=()

for block in "${FILE_BLOCKS[@]}"; do
  IFS='|' read -r masked_path orig_name orig_path <<< "$block"

  if [ ! -f "$masked_path" ]; then
    warn "[invoke-restore] Not found (skipping): $masked_path"
    failed=$((failed + 1))
    continue
  fi

  if mv "$masked_path" "$(dirname "$masked_path")/$orig_name" 2>/dev/null; then
    log_green "[invoke-restore] $(basename "$masked_path") -> $orig_name"
    restored=$((restored + 1))
    ORIG_PATHS+=("$orig_path")
  else
    warn "[invoke-restore] Failed: $masked_path"
    failed=$((failed + 1))
  fi
done

# ------------------------------------------------------------------
# Remove mapping
# ------------------------------------------------------------------
rm -f "$MAPPING_FILE"

# ------------------------------------------------------------------
# Git: undo skip-worktree
# ------------------------------------------------------------------
if [ -d "$WORKSPACE_ROOT/.git" ] && [ ${#ORIG_PATHS[@]} -gt 0 ]; then
  for orig_path in "${ORIG_PATHS[@]}"; do
    rel="${orig_path#$WORKSPACE_ROOT/}"
    git -C "$WORKSPACE_ROOT" update-index --no-skip-worktree -- "$rel" 2>/dev/null || true
  done
  log_gray "[invoke-restore] Removed git skip-worktree on ${#ORIG_PATHS[@]} file(s)"
fi

echo ""
if [ $failed -eq 0 ]; then
  log_green "[invoke-restore] Done. $restored file(s) restored."
else
  warn "[invoke-restore] Done. $restored restored, $failed failed."
  exit 1
fi
