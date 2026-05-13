#!/usr/bin/env bash
# =============================================================
# invoke-restore.sh
# Restore original sensitive filenames after Copilot session.
#
# Usage:
#   ./invoke-restore.sh
#   ./invoke-restore.sh /path/to/project
#   ./invoke-restore.sh /path/to/project --details
# =============================================================
set -euo pipefail

WORKSPACE_ROOT="${1:-$(pwd)}"
WORKSPACE_ROOT="${WORKSPACE_ROOT%/}"
MAPPING_FILE="$WORKSPACE_ROOT/.github/hooks/.masked-files.json"
SHOW_DETAILS=false
for arg in "$@"; do [ "$arg" = "--details" ] && SHOW_DETAILS=true; done

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------
log_green() { printf '\033[0;32m%s\033[0m\n' "$@"; }
log_yellow(){ printf '\033[0;33m%s\033[0m\n' "$@"; }
log_gray()  { printf '\033[0;90m%s\033[0m\n' "$@"; }
warn()      { printf '\033[0;33mWARN: %s\033[0m\n' "$@" >&2; }

# Convert Windows path to Unix path — used only for WORKSPACE_ROOT arg.
# Prefer cygpath; fall back to manual regex.
to_unix_path() {
  if command -v cygpath &>/dev/null; then
    cygpath -u "$1"
  else
    local p="${1//\\//}"
    [[ "$p" =~ ^([A-Za-z]):/(.*)$ ]] && echo "/${BASH_REMATCH[1],,}/${BASH_REMATCH[2]}" || echo "$p"
  fi
}

print_progress() {
  local label="$1" cur="$2" total="$3" eta="$4"
  local pct=$(( total > 0 ? cur * 100 / total : 100 ))
  local filled=$(( pct * 25 / 100 ))
  local bar=""
  for ((i=0; i<filled; i++));  do bar+="█"; done
  for ((i=filled; i<25; i++)); do bar+="░"; done
  printf '\r\033[K[invoke-restore] %s [%s] %d/%d (%d%%)  ETA: %ds' \
    "$label" "$bar" "$cur" "$total" "$pct" "$eta"
}

# ------------------------------------------------------------------
# Check mapping
# ------------------------------------------------------------------
# Normalize WORKSPACE_ROOT to Unix path (handles cases where the caller
# passed a Windows-style path, e.g. from a mixed PS/bash environment).
WORKSPACE_ROOT=$(to_unix_path "$WORKSPACE_ROOT")
MAPPING_FILE="$WORKSPACE_ROOT/.github/hooks/.masked-files.json"

if [ ! -f "$MAPPING_FILE" ]; then
  log_yellow "[invoke-restore] No mapping file found. Nothing to restore."
  exit 0
fi

# ------------------------------------------------------------------
# Parse mapping
# ------------------------------------------------------------------
# Strategy: prefer relative paths (maskedRelPath / originalRelPath)
# written by invoke-mask.ps1 / invoke-mask.sh — these are plain POSIX
# paths that need no conversion regardless of which OS created the map.
# Fall back to deriving relative paths from absolute paths when the
# mapping was created by an older version of the scripts.
#
# Output per line:  maskedRelPath|originalName
#
# Strip \r so Windows Python3 / awk CRLF output doesn't corrupt values.
readarray -t FILE_BLOCKS < <(
  python3 -c "
import json, sys, os
data = json.load(open('$MAPPING_FILE'))
ws = data.get('workspace', '')
for f in data.get('files', []):
    mrel = f.get('maskedRelPath') or ''
    oname = f.get('originalName', '')
    if not mrel:
        # Older mapping without relPath: derive from absolute path
        mp = f.get('maskedPath', '').replace('\\\\', '/').replace('\\\\', '/')
        if ws:
            ws_norm = ws.replace('\\\\', '/').replace('\\\\', '/')
            mrel = mp[len(ws_norm):].lstrip('/')
        else:
            mrel = os.path.basename(mp)
    print(mrel + '|' + oname)
" 2>/dev/null | tr -d '\r' || \
  # Fallback awk: ConvertTo-Json pretty-prints with space after ':'.
  # Use maskedRelPath when present; otherwise extract from maskedPath.
  awk -v ws="" '
    /\"workspace\"/ { match($0, /\"workspace\": *\"([^\"]+)\"/, a); ws=a[1] }
    /maskedRelPath/ { match($0, /\"maskedRelPath\": *\"([^\"]+)\"/, a); mrel=a[1] }
    /maskedPath/    { if (!mrel) { match($0, /\"maskedPath\": *\"([^\"]+)\"/, a); mp=a[1] } }
    /originalName/  { match($0, /\"originalName\": *\"([^\"]+)\"/, a); oname=a[1] }
    /originalPath/  {
      if (!mrel && mp != "") {
        # Derive relative path from absolute
        gsub(/\\\\/, "/", mp); gsub(/\\\\/, "/", ws)
        if (ws != "" && index(mp, ws) == 1)
          mrel = substr(mp, length(ws)+2)
        else
          { n=split(mp, parts, "/"); mrel=parts[n] }
      }
      if (oname != "") print mrel "|" oname
      mrel=""; mp=""; oname=""
    }
    END { if (oname != "") print mrel "|" oname }
  ' "$MAPPING_FILE" | tr -d '\r'
)

if [ ${#FILE_BLOCKS[@]} -eq 0 ]; then
  log_yellow "[invoke-restore] Mapping is empty. Nothing to restore."
  rm -f "$MAPPING_FILE"
  exit 0
fi

# ------------------------------------------------------------------
# Restore files (with progress + ETA)
# ------------------------------------------------------------------
restored=0
failed=0
RESTORE_TOTAL=${#FILE_BLOCKS[@]}
RESTORE_SECONDS_START=$SECONDS
declare -a ORIG_REL_PATHS=()

for idx in "${!FILE_BLOCKS[@]}"; do
  block="${FILE_BLOCKS[$idx]}"
  IFS='|' read -r masked_rel orig_name <<< "$block"

  # Skip blank entries (malformed JSON lines)
  if [ -z "$masked_rel" ] || [ -z "$orig_name" ]; then
    failed=$((failed + 1))
    continue
  fi

  masked_path="$WORKSPACE_ROOT/$masked_rel"
  # Derive orig_rel using bash parameter expansion (no subprocess)
  masked_dir="${masked_rel%/*}"
  if [ "$masked_dir" = "$masked_rel" ]; then
    orig_rel="$orig_name"          # file is in root, no subdir
  else
    orig_rel="$masked_dir/$orig_name"
  fi

  elapsed=$(( SECONDS - RESTORE_SECONDS_START ))
  rate=$(( elapsed > 0 && idx > 0 ? idx / elapsed : 1 ))
  eta=$(( rate > 0 ? (RESTORE_TOTAL - idx) / rate : 0 ))
  print_progress "Restoring" "$((idx+1))" "$RESTORE_TOTAL" "$eta"

  if [ ! -f "$masked_path" ]; then
    warn "[invoke-restore] Not found (skipping): $masked_rel"
    failed=$((failed + 1))
    continue
  fi

  if mv "$masked_path" "$WORKSPACE_ROOT/$orig_rel" 2>/dev/null; then
    $SHOW_DETAILS && log_green "[invoke-restore] $masked_rel -> $orig_name"
    restored=$((restored + 1))
    ORIG_REL_PATHS+=("$orig_rel")
  else
    warn "[invoke-restore] Failed: $masked_path"
    failed=$((failed + 1))
  fi
done
printf '\n'   # end progress line

# ------------------------------------------------------------------
# Remove mapping
# ------------------------------------------------------------------
rm -f "$MAPPING_FILE"

# ------------------------------------------------------------------
# Git: undo skip-worktree (batched)
# ------------------------------------------------------------------
if [ -d "$WORKSPACE_ROOT/.git" ] && [ ${#ORIG_REL_PATHS[@]} -gt 0 ]; then
  BATCH_SIZE=500
  batch=()
  for rel in "${ORIG_REL_PATHS[@]}"; do
    batch+=("$rel")
    if [ ${#batch[@]} -ge $BATCH_SIZE ]; then
      git -C "$WORKSPACE_ROOT" update-index --no-skip-worktree -- "${batch[@]}" 2>/dev/null || true
      batch=()
    fi
  done
  [ ${#batch[@]} -gt 0 ] && \
    git -C "$WORKSPACE_ROOT" update-index --no-skip-worktree -- "${batch[@]}" 2>/dev/null || true
  log_gray "[invoke-restore] Removed git skip-worktree on ${#ORIG_REL_PATHS[@]} file(s)"
fi

echo ""
if [ $failed -eq 0 ]; then
  log_green "[invoke-restore] Done. $restored file(s) restored."
else
  warn "[invoke-restore] Done. $restored restored, $failed failed."
  exit 1
fi
