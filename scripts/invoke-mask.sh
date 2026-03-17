#!/usr/bin/env bash
# =============================================================
# invoke-mask.sh
# Rename files with sensitive names (pure digits 9-16) to
# masked aliases before starting a Copilot session.
#
# Usage:
#   ./invoke-mask.sh
#   ./invoke-mask.sh /path/to/project
# =============================================================
set -euo pipefail

WORKSPACE_ROOT="${1:-$(pwd)}"
WORKSPACE_ROOT="${WORKSPACE_ROOT%/}"
MAPPING_FILE="$WORKSPACE_ROOT/.github/hooks/.masked-files.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------
sha1_hash() {
  local input="$1"
  if command -v shasum &>/dev/null; then
    printf '%s' "$input" | shasum -a 1 | awk '{print $1}' | cut -c1-8
  else
    printf '%s' "$input" | sha1sum | awk '{print $1}' | cut -c1-8
  fi
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
# Scan for sensitive filenames
# ------------------------------------------------------------------
declare -a ORIG_PATHS=()
declare -a MASKED_PATHS=()
declare -a ORIG_NAMES=()
declare -a MASKED_NAMES=()

while IFS= read -r -d '' filepath; do
  filename="$(basename "$filepath")"
  basename_no_ext="${filename%.*}"
  ext="${filename##*.}"
  [ "$ext" = "$filename" ] && ext="" || ext=".$ext"

  if [[ "$basename_no_ext" =~ ^[0-9]{9,16}$ ]]; then
    hash=$(sha1_hash "$filepath")
    masked_name="masked-${hash}${ext}"
    masked_path="$(dirname "$filepath")/$masked_name"

    ORIG_PATHS+=("$filepath")
    MASKED_PATHS+=("$masked_path")
    ORIG_NAMES+=("$filename")
    MASKED_NAMES+=("$masked_name")
  fi
done < <(find "$WORKSPACE_ROOT" -type f -not -path "*/.git/*" -print0)

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

  for filepath in "${ORIG_PATHS[@]}"; do
    rel="${filepath#$WORKSPACE_ROOT/}"
    git -C "$WORKSPACE_ROOT" update-index --skip-worktree -- "$rel" 2>/dev/null || true
  done
  log_gray "[invoke-mask] Applied git skip-worktree on ${#ORIG_PATHS[@]} file(s)"
fi

# ------------------------------------------------------------------
# Rename files + build JSON mapping
# ------------------------------------------------------------------
succeeded=0
JSON_FILES="["
first=true

for i in "${!ORIG_PATHS[@]}"; do
  orig="${ORIG_PATHS[$i]}"
  masked="${MASKED_PATHS[$i]}"
  orig_name="${ORIG_NAMES[$i]}"
  masked_name="${MASKED_NAMES[$i]}"

  if mv "$orig" "$masked" 2>/dev/null; then
    log_cyan "[invoke-mask] $orig_name -> $masked_name"
    succeeded=$((succeeded + 1))

    $first || JSON_FILES+=","
    first=false
    JSON_FILES+=$(printf '{"originalPath":"%s","maskedPath":"%s","originalName":"%s","maskedName":"%s"}' \
      "$orig" "$masked" "$orig_name" "$masked_name")
  else
    warn "[invoke-mask] Failed to rename: $orig"
  fi
done

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
