#!/usr/bin/env bash
# =============================================================
# invoke-mask.sh
# Rename files with sensitive names (pure digits 9-16) to
# masked aliases before starting a Copilot session.
#
# Usage:
#   ./invoke-mask.sh
#   ./invoke-mask.sh /path/to/project
#   ./invoke-mask.sh /path/to/project --details
# =============================================================
set -euo pipefail

WORKSPACE_ROOT="${1:-$(pwd)}"
WORKSPACE_ROOT="${WORKSPACE_ROOT%/}"
MAPPING_FILE="$WORKSPACE_ROOT/.github/hooks/.masked-files.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHOW_DETAILS=false
for arg in "$@"; do [ "$arg" = "--details" ] && SHOW_DETAILS=true; done

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------
# MD5 is ~30% faster than SHA-1 and sufficient for collision-resistant
# 8-char aliases.  Instance reuse is not applicable in bash (each call
# is a subprocess), so we minimise overhead by picking the fastest
# available command.
md5_hash() {
  local input="$1"
  if command -v md5sum &>/dev/null; then
    printf '%s' "$input" | md5sum | cut -c1-8
  elif command -v md5 &>/dev/null; then
    printf '%s' "$input" | md5 -q | cut -c1-8
  else
    # last-resort fallback to sha1
    printf '%s' "$input" | sha1sum | cut -c1-8
  fi
}

# Progress bar: overwrites current line (no newline until phase ends)
print_progress() {
  local label="$1" cur="$2" total="$3" extra="$4" eta="$5"
  local pct=$(( total > 0 ? cur * 100 / total : 100 ))
  local filled=$(( pct * 25 / 100 ))   # 25-char bar
  local bar=""
  for ((i=0; i<filled; i++));      do bar+="█"; done
  for ((i=filled; i<25; i++));     do bar+="░"; done
  printf '\r\033[K[invoke-mask] %s [%s] %d/%d (%d%%)  %s  ETA: %ds' \
    "$label" "$bar" "$cur" "$total" "$pct" "$extra" "$eta"
}

log()      { echo "$@"; }
log_cyan() { printf '\033[0;36m%s\033[0m\n' "$@"; }
log_green(){ printf '\033[0;32m%s\033[0m\n' "$@"; }
log_yellow(){ printf '\033[0;33m%s\033[0m\n' "$@"; }
log_gray() { printf '\033[0;90m%s\033[0m\n' "$@"; }
warn()     { printf '\033[0;33mWARN: %s\033[0m\n' "$@" >&2; }

# ------------------------------------------------------------------
# Safety: if mapping exists, restore first
# ------------------------------------------------------------------
if [ -f "$MAPPING_FILE" ]; then
  log_yellow "[invoke-mask] Found existing mapping — running restore first..."
  bash "$SCRIPT_DIR/invoke-restore.sh" "$WORKSPACE_ROOT"
fi

# ------------------------------------------------------------------
# Scan for sensitive filenames (with progress)
# ------------------------------------------------------------------
# Pre-count total files so we can show accurate % and ETA
printf '[invoke-mask] Counting files...\r'
TOTAL_FILES=$(find "$WORKSPACE_ROOT" -type f -not -path "*/.git/*" | wc -l | tr -d ' ')
printf '\033[K'   # clear the counting line
echo "[invoke-mask] $TOTAL_FILES file(s) to scan."

declare -a ORIG_PATHS=()
declare -a MASKED_PATHS=()
declare -a ORIG_NAMES=()
declare -a MASKED_NAMES=()

SCAN_IDX=0
SCAN_START=$(date +%s)

while IFS= read -r -d '' filepath; do
  SCAN_IDX=$((SCAN_IDX + 1))
  filename="$(basename "$filepath")"
  basename_no_ext="${filename%.*}"
  ext="${filename##*.}"
  [ "$ext" = "$filename" ] && ext="" || ext=".$ext"

  if [[ "$basename_no_ext" =~ ^[0-9]{9,16}$ ]]; then
    hash=$(md5_hash "$filepath")
    masked_name="masked-${hash}${ext}"
    masked_path="$(dirname "$filepath")/$masked_name"

    ORIG_PATHS+=("$filepath")
    MASKED_PATHS+=("$masked_path")
    ORIG_NAMES+=("$filename")
    MASKED_NAMES+=("$masked_name")
  fi

  if (( SCAN_IDX % 200 == 0 || SCAN_IDX == TOTAL_FILES )); then
    elapsed=$(( $(date +%s) - SCAN_START ))
    rate=$(( elapsed > 0 ? SCAN_IDX / elapsed : SCAN_IDX ))
    eta=$(( rate > 0 ? (TOTAL_FILES - SCAN_IDX) / rate : 0 ))
    print_progress "Scanning" "$SCAN_IDX" "$TOTAL_FILES" "Found: ${#ORIG_PATHS[@]}" "$eta"
  fi
done < <(find "$WORKSPACE_ROOT" -type f -not -path "*/.git/*" -print0)
printf '\n'
echo "[invoke-mask] Scan complete — ${#ORIG_PATHS[@]} sensitive file(s) found."

if [ ${#ORIG_PATHS[@]} -eq 0 ]; then
  log_green "[invoke-mask] No sensitive filenames found. Nothing to do."
  exit 0
fi

# ------------------------------------------------------------------
# Git: skip-worktree + gitignore
# ------------------------------------------------------------------
IS_GIT_REPO=false
[ -d "$WORKSPACE_ROOT/.git" ] && IS_GIT_REPO=true

if $IS_GIT_REPO; then
  GITIGNORE="$WORKSPACE_ROOT/.gitignore"
  IGNORE_ENTRY="masked-*"
  MAPPING_ENTRY=".github/hooks/.masked-files.json"

  touch "$GITIGNORE"
  if ! grep -qxF "$IGNORE_ENTRY" "$GITIGNORE"; then
    printf '\n# Temporary masked aliases (invoke-mask / invoke-restore)\n%s\n' "$IGNORE_ENTRY" >> "$GITIGNORE"
  fi
  if ! grep -qxF "$MAPPING_ENTRY" "$GITIGNORE"; then
    printf '%s\n' "$MAPPING_ENTRY" >> "$GITIGNORE"
    log_gray "[invoke-mask] .gitignore updated"
  fi

  # Batch: max 500 paths per git call to avoid ARG_MAX limits
  BATCH_SIZE=500
  batch=()
  for filepath in "${ORIG_PATHS[@]}"; do
    rel="${filepath#$WORKSPACE_ROOT/}"
    batch+=("$rel")
    if [ ${#batch[@]} -ge $BATCH_SIZE ]; then
      git -C "$WORKSPACE_ROOT" update-index --skip-worktree -- "${batch[@]}" 2>/dev/null || true
      batch=()
    fi
  done
  [ ${#batch[@]} -gt 0 ] && \
    git -C "$WORKSPACE_ROOT" update-index --skip-worktree -- "${batch[@]}" 2>/dev/null || true

  log_gray "[invoke-mask] Applied git skip-worktree on ${#ORIG_PATHS[@]} file(s)"
fi

# ------------------------------------------------------------------
# Rename files + build JSON mapping (with progress)
# ------------------------------------------------------------------
succeeded=0
RENAME_TOTAL=${#ORIG_PATHS[@]}
RENAME_START=$(date +%s)
JSON_FILES="["
first=true

for i in "${!ORIG_PATHS[@]}"; do
  orig="${ORIG_PATHS[$i]}"
  masked="${MASKED_PATHS[$i]}"
  orig_name="${ORIG_NAMES[$i]}"
  masked_name="${MASKED_NAMES[$i]}"

  elapsed=$(( $(date +%s) - RENAME_START ))
  rate=$(( elapsed > 0 && i > 0 ? i / elapsed : 1 ))
  eta=$(( rate > 0 ? (RENAME_TOTAL - i) / rate : 0 ))
  print_progress "Renaming" "$((i+1))" "$RENAME_TOTAL" "" "$eta"

  if mv "$orig" "$masked" 2>/dev/null; then
    $SHOW_DETAILS && log_cyan "[invoke-mask] $orig_name -> $masked_name"
    succeeded=$((succeeded + 1))

    $first || JSON_FILES+=","
    first=false
    JSON_FILES+=$(printf '{"originalPath":"%s","maskedPath":"%s","originalName":"%s","maskedName":"%s"}' \
      "$orig" "$masked" "$orig_name" "$masked_name")
  else
    warn "[invoke-mask] Failed to rename: $orig"
  fi
done
printf '\n'   # end progress line

JSON_FILES+="]"

# ------------------------------------------------------------------
# Save mapping
# ------------------------------------------------------------------
mkdir -p "$(dirname "$MAPPING_FILE")"
created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > "$MAPPING_FILE" <<EOF
{
  "createdAt": "$created_at",
  "workspace": "$WORKSPACE_ROOT",
  "files": $JSON_FILES
}
EOF

log ""
log_green "[invoke-mask] Done. $succeeded file(s) masked."
log_gray  "[invoke-mask] Mapping: $MAPPING_FILE"
log_yellow "[invoke-mask] Run ./invoke-restore.sh when your Copilot session ends."
