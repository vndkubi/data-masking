#!/usr/bin/env bash

demo_ts() { date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' 'unknown'; }

DEMO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_HOOKS_DIR="$(dirname "$DEMO_LIB_DIR")"
DEMO_DIAG_DIR="$DEMO_HOOKS_DIR/logs"
mkdir -p "$DEMO_DIAG_DIR" 2>/dev/null || true
DEMO_DIAG_FILE="$DEMO_DIAG_DIR/hook-debug.log"

DEMO_HOOK_EVENT=""
DEMO_CWD="."
DEMO_CONFIG_PATH=""
DEMO_CLEAN_CONFIG=""
DEMO_AUDIT_FILE=""
DEMO_EXTERNAL_TOOLS_REGEX='^(search_web|fetch_webpage|mcp_.*|github_repo|external_api_call)$'
DEMO_FALLBACK_SENSITIVE_REGEX='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'

demo_diag() {
  printf '[%s] %s\n' "$(demo_ts)" "$1" >> "$DEMO_DIAG_FILE" 2>/dev/null || true
}

demo_cleanup() {
  if [ -n "${DEMO_CLEAN_CONFIG:-}" ] && [ -f "$DEMO_CLEAN_CONFIG" ]; then
    rm -f "$DEMO_CLEAN_CONFIG" 2>/dev/null || true
  fi
}

demo_read_input() {
  cat 2>/dev/null || true
}

demo_to_unix_path() {
  local path="$1"
  if [[ "$path" =~ ^[A-Za-z]:[/\\] ]]; then
    local drive="${path:0:1}"
    local rest="${path:2}"
    drive=$(printf '%s' "$drive" | tr '[:upper:]' '[:lower:]')
    rest="${rest//\\//}"
    path="/${drive}${rest}"
  fi
  printf '%s' "$path"
}

demo_load_config() {
  local raw_config_path="$DEMO_CWD/.github/hooks/masking-config.json"
  if [ ! -f "$raw_config_path" ]; then
    DEMO_CONFIG_PATH=""
    return 0
  fi

  DEMO_CLEAN_CONFIG=$(mktemp 2>/dev/null || printf '/tmp/hook-demo-config.json')
  sed '/^[[:space:]]*\/\//d' "$raw_config_path" > "$DEMO_CLEAN_CONFIG" 2>/dev/null || true
  DEMO_CONFIG_PATH="$DEMO_CLEAN_CONFIG"

  local override_regex
  override_regex=$(jq -r '.externalToolsRegex // empty' "$DEMO_CONFIG_PATH" 2>/dev/null || true)
  if [ -n "$override_regex" ]; then
    DEMO_EXTERNAL_TOOLS_REGEX="$override_regex"
  fi
}

demo_init_context() {
  local input="$1"
  DEMO_HOOK_EVENT=$(printf '%s' "$input" | jq -r '.hook_event_name // .hookEventName // empty' 2>/dev/null || true)
  if [ -z "$DEMO_HOOK_EVENT" ]; then
    demo_diag 'No hook event found in payload'
    return 1
  fi

  DEMO_CWD=$(printf '%s' "$input" | jq -r '.cwd // "."' 2>/dev/null || printf '.')
  DEMO_CWD=$(demo_to_unix_path "$DEMO_CWD")
  mkdir -p "$DEMO_CWD/logs" 2>/dev/null || true
  DEMO_AUDIT_FILE="$DEMO_CWD/logs/copilot-mask-audit.log"
  demo_load_config
  demo_diag "Initialized support escalation demo for $DEMO_HOOK_EVENT"
  return 0
}

demo_audit() {
  local event="$1"
  local detail="$2"
  if [ -n "$DEMO_AUDIT_FILE" ]; then
    printf '[%s] [%s] %s\n' "$(demo_ts)" "$event" "$detail" >> "$DEMO_AUDIT_FILE" 2>/dev/null || true
  fi
}

_demo_replace() {
  local regex="$1"
  local replacement="$2"
  local content="$3"

  replacement=$(printf '%s' "$replacement" | sed 's/\$\([0-9]\)/\\\1/g')
  if command -v perl >/dev/null 2>&1; then
    printf '%s' "$content" | perl -pe '
      BEGIN { $r = shift; $s = shift; }
      s/$r/$s/gi;
    ' -- "$regex" "$replacement" 2>/dev/null && return
  fi

  printf '%s' "$content" | sed -E "s#${regex}#${replacement}#gI" 2>/dev/null || printf '%s' "$content"
}

demo_mask_sensitive() {
  local content="$1"

  if [ -z "$DEMO_CONFIG_PATH" ] || [ ! -f "$DEMO_CONFIG_PATH" ]; then
    printf '%s' "$content" | perl -pe 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/[MASKED-EMAIL]/gi' 2>/dev/null || printf '%s' "$content"
    return 0
  fi

  local result="$content"
  local pattern_count
  local index

  pattern_count=$(jq '(.patterns // []) | length' "$DEMO_CONFIG_PATH" 2>/dev/null || printf '0')
  index=0
  while [ "$index" -lt "$pattern_count" ]; do
    local enabled regex regex_bash replacement active_regex
    enabled=$(jq -r ".patterns[$index].enabled // true" "$DEMO_CONFIG_PATH" 2>/dev/null || printf 'true')
    if [ "$enabled" = "false" ]; then
      index=$((index + 1))
      continue
    fi
    regex_bash=$(jq -r ".patterns[$index].regexBash // empty" "$DEMO_CONFIG_PATH" 2>/dev/null || true)
    regex=$(jq -r ".patterns[$index].regex // empty" "$DEMO_CONFIG_PATH" 2>/dev/null || true)
    replacement=$(jq -r ".patterns[$index].replacement // empty" "$DEMO_CONFIG_PATH" 2>/dev/null || true)
    active_regex="${regex_bash:-$regex}"
    active_regex=$(printf '%s' "$active_regex" | sed 's/(?i)//g')
    if [ -n "$active_regex" ] && [ -n "$replacement" ]; then
      result=$(_demo_replace "$active_regex" "$replacement" "$result")
    fi
    index=$((index + 1))
  done

  local custom_count
  custom_count=$(jq '(.customPatterns // []) | length' "$DEMO_CONFIG_PATH" 2>/dev/null || printf '0')
  index=0
  while [ "$index" -lt "$custom_count" ]; do
    local custom_regex custom_replacement
    custom_regex=$(jq -r ".customPatterns[$index].regex // empty" "$DEMO_CONFIG_PATH" 2>/dev/null || true)
    custom_replacement=$(jq -r ".customPatterns[$index].replacement // .customPatterns[$index].name // empty" "$DEMO_CONFIG_PATH" 2>/dev/null || true)
    custom_regex=$(printf '%s' "$custom_regex" | sed 's/(?i)//g')
    if [ -n "$custom_regex" ] && [ -n "$custom_replacement" ]; then
      result=$(_demo_replace "$custom_regex" "$custom_replacement" "$result")
    fi
    index=$((index + 1))
  done

  printf '%s' "$result"
}

demo_has_sensitive() {
  local content="$1"

  if [ -z "$DEMO_CONFIG_PATH" ] || [ ! -f "$DEMO_CONFIG_PATH" ]; then
    printf '%s' "$content" | grep -qiE "$DEMO_FALLBACK_SENSITIVE_REGEX" 2>/dev/null
    return $?
  fi

  local pattern_count
  local index
  pattern_count=$(jq '(.patterns // []) | length' "$DEMO_CONFIG_PATH" 2>/dev/null || printf '0')
  index=0
  while [ "$index" -lt "$pattern_count" ]; do
    local enabled regex regex_bash active_regex
    enabled=$(jq -r ".patterns[$index].enabled // true" "$DEMO_CONFIG_PATH" 2>/dev/null || printf 'true')
    if [ "$enabled" = "false" ]; then
      index=$((index + 1))
      continue
    fi
    regex_bash=$(jq -r ".patterns[$index].regexBash // empty" "$DEMO_CONFIG_PATH" 2>/dev/null || true)
    regex=$(jq -r ".patterns[$index].regex // empty" "$DEMO_CONFIG_PATH" 2>/dev/null || true)
    active_regex="${regex_bash:-$regex}"
    active_regex=$(printf '%s' "$active_regex" | sed 's/(?i)//g')
    if [ -n "$active_regex" ] && printf '%s' "$content" | grep -qiE "$active_regex" 2>/dev/null; then
      return 0
    fi
    index=$((index + 1))
  done

  local custom_count
  custom_count=$(jq '(.customPatterns // []) | length' "$DEMO_CONFIG_PATH" 2>/dev/null || printf '0')
  index=0
  while [ "$index" -lt "$custom_count" ]; do
    local custom_regex
    custom_regex=$(jq -r ".customPatterns[$index].regex // empty" "$DEMO_CONFIG_PATH" 2>/dev/null || true)
    custom_regex=$(printf '%s' "$custom_regex" | sed 's/(?i)//g')
    if [ -n "$custom_regex" ] && printf '%s' "$content" | grep -qiE "$custom_regex" 2>/dev/null; then
      return 0
    fi
    index=$((index + 1))
  done

  return 1
}

demo_resolve_file_path() {
  local file_path="$1"
  file_path=$(demo_to_unix_path "$file_path")
  if [[ "$file_path" != /* ]]; then
    file_path="$DEMO_CWD/$file_path"
  fi
  printf '%s' "$file_path"
}