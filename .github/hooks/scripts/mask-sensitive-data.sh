#!/usr/bin/env bash
# =============================================================
# Sensitive Data Masker - Copilot Agent Hook
# Handles: SessionStart, UserPromptSubmit, PreToolUse,
#           PreCompact, SubagentStart
# Platforms: Linux, macOS, WSL, Git Bash (Windows)
# =============================================================
# NOTE: Do NOT use "set -e" here. Some commands (GNU sed -E gI on
#       macOS, grep with no match, etc.) return non-zero legitimately.
#       Every critical command already has explicit error handling.

# Portable timestamp helper (BSD date on macOS lacks some GNU flags
# but -u +'fmt' works on both).
_ts() { date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' 'unknown'; }

# Early diagnostic breadcrumb
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIAG_DIR="$(dirname "$SCRIPT_DIR")/logs"
mkdir -p "$DIAG_DIR" 2>/dev/null || true
DIAG_FILE="$DIAG_DIR/hook-debug.log"
printf '[%s] Script invoked, SCRIPT_DIR=%s\n' "$(_ts)" "$SCRIPT_DIR" >> "$DIAG_FILE" 2>/dev/null || true

# ==============================================================
# DEPENDENCY CHECK: jq is required
# ==============================================================
if ! command -v jq &>/dev/null; then
    printf '[%s] ERROR: jq not found. Install it first:\n' "$(_ts)" >> "$DIAG_FILE" 2>/dev/null || true
    printf '[%s]   Ubuntu/WSL: sudo apt-get install -y jq\n' "$(_ts)" >> "$DIAG_FILE" 2>/dev/null || true
    printf '[%s]   macOS:      brew install jq\n' "$(_ts)" >> "$DIAG_FILE" 2>/dev/null || true
    printf '[%s]   Windows:    winget install jqlang.jq OR choco install jq\n' "$(_ts)" >> "$DIAG_FILE" 2>/dev/null || true
    exit 0
fi

# ==============================================================
# CROSS-PLATFORM HELPERS
# ==============================================================

# Convert Windows-style path (C:\foo\bar or C:/foo/bar) to Unix path.
# Uses pure-bash conversion (no wslpath) to avoid WSL relay errors.
to_unix_path() {
    local p="$1"
    if [[ "$p" =~ ^[A-Za-z]:[/\\] ]]; then
        # Pure-bash conversion: C:\foo -> /c/foo
        # Works in Git Bash, MSYS2, and WSL without invoking wslpath
        # (wslpath triggers WSL relay errors when no distro is installed).
        local drive="${p:0:1}"
        local rest="${p:2}"
        drive=$(printf '%s' "$drive" | tr '[:upper:]' '[:lower:]')
        rest="${rest//\\//}"
        p="/${drive}${rest}"
    fi
    printf '%s' "$p"
}

# Cross-platform case-insensitive sed/perl substitute.
# Strategy: use perl first (reliable, handles (?i), backrefs, alternation).
# Falls back to GNU sed only if perl is absent.
# Why perl first? BSD sed (macOS) doesn't support the I (case-insensitive)
# flag, and using | as sed delimiter breaks when regex contains alternation |.
_sed_replace() {
    local regex="$1"
    local replacement="$2"
    local content="$3"

    # Normalize backreferences: $1 -> \1 for perl/sed
    replacement=$(printf '%s' "$replacement" | sed 's/\$\([0-9]\)/\\\1/g')

    # Prefer perl — available on macOS, most Linux distros, Git Bash (via Git)
    if command -v perl &>/dev/null; then
        printf '%s' "$content" | perl -pe "
            BEGIN { \$r = shift; \$s = shift; }
            s/\$r/\$s/gi;
        " -- "$regex" "$replacement" 2>/dev/null && return
    fi

    # Fallback: GNU sed with case-insensitive flag (Linux/WSL only)
    # Use ASCII 0x01 as delimiter to avoid conflicts with regex chars
    local delim=$'\x01'
    local out
    out=$(printf '%s' "$content" | sed -E "s${delim}${regex}${delim}${replacement}${delim}gI" 2>/dev/null) \
        && { printf '%s' "$out"; return; }

    # Last resort: return content unchanged
    printf '%s' "$content"
}

# Read stdin with error handling
INPUT=$(cat 2>/dev/null || true)

if [ -z "$INPUT" ]; then
    printf '[%s] STDIN EMPTY - no hook data received\n' "$(_ts)" >> "$DIAG_FILE" 2>/dev/null || true
    exit 0
fi

HOOK_EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // .hookEventName // empty' 2>/dev/null)
if [ -z "$HOOK_EVENT" ]; then
    printf '[%s] JSON PARSE FAILED or no hookEventName\n' "$(_ts)" >> "$DIAG_FILE" 2>/dev/null || true
    exit 0
fi

printf '[%s] Hook event: %s\n' "$(_ts)" "$HOOK_EVENT" >> "$DIAG_FILE" 2>/dev/null || true

# ==============================================================
# CONFIGURATION
# ==============================================================
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // "."')
# Normalize path so WSL can handle Windows-style CWD (e.g. C:\Users\...)
CWD=$(to_unix_path "$CWD")
CONFIG_PATH="$CWD/.github/hooks/masking-config.json"
EXTERNAL_TOOLS_REGEX="^(search_web|fetch_webpage|mcp_.*|github_repo)$"

# Load config if exists
# NOTE: masking-config.json uses JSONC syntax (// comments). Strip comment lines
#       before passing to jq, which only accepts standard JSON.
if [ -f "$CONFIG_PATH" ]; then
  _CLEAN_CONFIG=$(mktemp 2>/dev/null || printf '/tmp/mask-config-clean.json')
  # Strip JSONC comment lines, then trailing commas before ] or } (perl -0777 slurps whole file)
  sed '/^[[:space:]]*\/\//d' "$CONFIG_PATH" \
    | perl -0777 -pe 's/,(\s*[}\]])/$1/g' \
    > "$_CLEAN_CONFIG" 2>/dev/null || true
  # Replace CONFIG_PATH with the comment-stripped version for all subsequent jq calls
  CONFIG_PATH="$_CLEAN_CONFIG"
  trap 'rm -f "$_CLEAN_CONFIG"' EXIT
  # Parse external tools regex if overridden
  NEW_EXT_REGEX=$(jq -r '.externalToolsRegex // empty' "$CONFIG_PATH" 2>/dev/null || true)
  if [ -n "$NEW_EXT_REGEX" ]; then
    EXTERNAL_TOOLS_REGEX="$NEW_EXT_REGEX"
  fi
fi

# ==============================================================
# MASKING PATTERNS
# Order matters: longer digit patterns first to avoid partial matches
# ==============================================================

mask_sensitive() {
  local content="$1"

  if [ -f "$CONFIG_PATH" ]; then
    # Apply built-in patterns from config
    local pattern_count i
    pattern_count=$(jq '(.patterns // []) | length' "$CONFIG_PATH" 2>/dev/null || printf '0')
    i=0
    while [ "$i" -lt "$pattern_count" ]; do
      local enabled regex regexBash replacement active_regex
      enabled=$(jq -r ".patterns[$i].enabled // true" "$CONFIG_PATH" 2>/dev/null || printf 'true')
      if [ "$enabled" = "false" ]; then
        i=$((i + 1)); continue
      fi
      regexBash=$(jq -r ".patterns[$i].regexBash // empty" "$CONFIG_PATH" 2>/dev/null || true)
      regex=$(jq -r ".patterns[$i].regex // empty" "$CONFIG_PATH" 2>/dev/null || true)
      replacement=$(jq -r ".patterns[$i].replacement // .patterns[$i].name // empty" "$CONFIG_PATH" 2>/dev/null || true)
      active_regex="${regexBash:-$regex}"
      # Strip PCRE inline (?i) flag - case-insensitivity handled by _sed_replace
      active_regex=$(printf '%s' "$active_regex" | sed 's/(?i)//g')
      if [ -n "$active_regex" ] && [ -n "$replacement" ]; then
        content=$(_sed_replace "$active_regex" "$replacement" "$content")
      fi
      i=$((i + 1))
    done

    # Apply custom patterns from config
    local cpattern_count
    cpattern_count=$(jq '(.customPatterns // []) | length' "$CONFIG_PATH" 2>/dev/null || printf '0')
    i=0
    while [ "$i" -lt "$cpattern_count" ]; do
      local cregex cname
      cregex=$(jq -r ".customPatterns[$i].regex // empty" "$CONFIG_PATH" 2>/dev/null || true)
      cname=$(jq -r ".customPatterns[$i].replacement // .customPatterns[$i].name // empty" "$CONFIG_PATH" 2>/dev/null || true)
      cregex=$(printf '%s' "$cregex" | sed 's/(?i)//g')
      if [ -n "$cregex" ] && [ -n "$cname" ]; then
        content=$(_sed_replace "$cregex" "$cname" "$content")
      fi
      i=$((i + 1))
    done
  fi

  printf '%s' "$content"
}

# Quick check if content likely contains sensitive patterns
has_sensitive() {
  local content="$1"
  local combined_regex=""

  if [ -f "$CONFIG_PATH" ]; then
    # Prefer regexBash (ERE-compatible) over regex (PCRE).
    # Skip multi-line patterns (those with [\s\S]) as grep is line-based.
    # Convert remaining PCRE escapes (\d, \s) to POSIX ERE equivalents.
    combined_regex=$(jq -r '
      [(.patterns // [])[],  (.customPatterns // [])[]]
      | map(select(.enabled != false))
      | map(.regexBash // .regex // empty)
      | map(select(. != null and . != "" and (contains("[\\s\\S]") | not) and (contains("[^-]*") | not)))
      | join("|")
    ' "$CONFIG_PATH" 2>/dev/null \
      | sed 's/(?i)//g; s/\\d/[0-9]/g; s/\\s/[[:space:]]/g' || true)
  fi

  if [ -n "$combined_regex" ]; then
    printf '%s' "$content" | grep -qiE "$combined_regex" 2>/dev/null
  else
    # Fallback if config is unavailable
    printf '%s' "$content" | grep -qiE '[0-9]{16}' 2>/dev/null
  fi
}

# ==============================================================
# AUDIT LOG (append-only, no sensitive data in log)
# ==============================================================
audit_log() {
  local event="$1"
  local detail="$2"
  # Use already-normalized CWD (not raw Windows path from JSON)
  local log_dir="${CWD}/logs"
  mkdir -p "$log_dir" 2>/dev/null || true
  local log_file="$log_dir/copilot-mask-audit.log"
  printf '[%s] [%s] %s\n' "$(_ts)" "${event}" "${detail}" >> "$log_file" 2>/dev/null || true
}

# ==============================================================
# DISPATCH BY HOOK EVENT
# ==============================================================

case "$HOOK_EVENT" in

  "PreToolUse")
    TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // .toolName // "unknown"')

    # Extract tool input (VS Code may use: input, toolInput, tool_input, or toolArgs)
    TOOL_INPUT_STR=$(printf '%s' "$INPUT" | jq -c '.tool_input // .toolInput // .input // .toolArgs // {}')

    audit_log "PreToolUse-Debug" "tool=${TOOL_NAME}, keys=$(printf '%s' "$INPUT" | jq -r 'keys | join(",")')"

    if [ -n "$TOOL_INPUT_STR" ] && [ "$TOOL_INPUT_STR" != "{}" ] && [ "$TOOL_INPUT_STR" != "null" ]; then

      # --- Egress Protection: ASK user before sending sensitive data to external tools ---
      if printf '%s' "$TOOL_NAME" | grep -qiE "$EXTERNAL_TOOLS_REGEX" 2>/dev/null; then
        if has_sensitive "$TOOL_INPUT_STR"; then
          audit_log "PreToolUse (Egress)" "CONFIRM REQUIRED: External tool '${TOOL_NAME}' contains sensitive data."
          jq -n \
            --arg tool "$TOOL_NAME" \
            '{
              "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "ask",
                "permissionDecisionReason": ("Sensitive data detected in the input to '\''" + $tool + "'\'' Do you want to send this data to the external service? If yes, consider whether the data should be masked first.")
              }
            }'
          exit 0
        fi
      fi

      # --- Strategy 1: DENY file operations with sensitive file paths ---
      _path_regex=""
      if [ -f "$CONFIG_PATH" ]; then
        _path_regex=$(jq -r '[(.patterns // [])[].regex, (.customPatterns // [])[].regex] | map(select(. != null and . != "")) | join("|")' "$CONFIG_PATH" 2>/dev/null | sed 's/(?i)//g' || true)
      fi
      [ -z "$_path_regex" ] && _path_regex='[0-9]{16}'
      audit_log "Strategy1-Debug" "tool=${TOOL_NAME} | regex_built=$([ -n "$_path_regex" ] && printf 'yes' || printf 'no') | input_len=${#TOOL_INPUT_STR}"
      if printf '%s' "$TOOL_INPUT_STR" | grep -qiE "(filePath|file_path|path|file)[^}]*(${_path_regex})"; then
        audit_log "PreToolUse" "DENIED: File path with sensitive pattern in tool: ${TOOL_NAME}"
        jq -n '{
          "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": "BLOCKED by security policy: The file path contains a pattern matching sensitive data. Reading or modifying files with PII in the name is not allowed. Please rename the file to remove sensitive identifiers first."
          }
        }'
        exit 0
      fi

      # --- Strategy 2: PRE-READ file content and deny if sensitive ---
      if [ "$TOOL_NAME" = "read_file" ] || [ "$TOOL_NAME" = "readFile" ]; then
        FILE_PATH=$(printf '%s' "$TOOL_INPUT_STR" | jq -r '.filePath // .file_path // .path // empty')
        if [ -n "$FILE_PATH" ]; then
          # Normalize Windows-style path (WSL support)
          FILE_PATH=$(to_unix_path "$FILE_PATH")
          # Resolve relative path
          if [[ "$FILE_PATH" != /* ]]; then
            FILE_PATH="${CWD}/${FILE_PATH}"
          fi
          if [ -f "$FILE_PATH" ]; then
            FILE_CONTENT=$(cat "$FILE_PATH" 2>/dev/null || true)
            if [ -n "$FILE_CONTENT" ] && has_sensitive "$FILE_CONTENT"; then
              MASKED_CONTENT=$(mask_sensitive "$FILE_CONTENT")
              audit_log "PreToolUse" "DENIED read_file: sensitive content in ${FILE_PATH}"
              jq -n \
                --arg masked "$MASKED_CONTENT" \
                '{
                  "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": ("SECURITY: File contains sensitive data. Here is the sanitized content:\n" + $masked + "\nIMPORTANT: Use ONLY this masked version. Read only masked content.")
                  }
                }'
              exit 0
            fi
          fi
        fi
      fi

      # --- Strategy 3: MASK sensitive data in tool arguments (commands, etc.) ---
      MASKED_STR=$(mask_sensitive "$TOOL_INPUT_STR")

      if [ "$TOOL_INPUT_STR" != "$MASKED_STR" ]; then
        audit_log "PreToolUse" "Sensitive data masked in tool: ${TOOL_NAME}"

        UPDATED_INPUT=$(printf '%s' "$MASKED_STR" | jq '.' 2>/dev/null || printf '%s' "$MASKED_STR")

        jq -n \
          --argjson updated "$UPDATED_INPUT" \
          '{
            "hookSpecificOutput": {
              "hookEventName": "PreToolUse",
              "permissionDecision": "allow",
              "permissionDecisionReason": "Sensitive data was detected and masked before tool execution",
              "updatedInput": $updated,
              "additionalContext": "WARNING: Sensitive data was detected in tool input and has been automatically masked with [MASKED-*] placeholders. Do NOT attempt to unmask, recover, or reconstruct the original values."
            }
          }'
        exit 0
      fi
    fi
    # No sensitive data found - allow silently
    ;;

  "SessionStart")
    jq -n '{
      "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "SECURITY POLICY ACTIVE - SENSITIVE DATA MASKING:\nSensitive data in this session has been automatically masked with [MASKED-*] placeholders.\n\nRULES:\n1. Always use the masked placeholder (e.g. [MASKED-CC], [MASKED-KEY], [MASKED-ID]) when referencing sensitive values - never reconstruct or reveal the originals.\n2. When passing data to ANY tool call, external service, MCP tool, or API - use ONLY the masked version.\n3. When storing or summarising information into context (memory, compaction, subagent hand-off) - use ONLY the masked version.\n4. If you receive a [MASKED-*] value, treat it as the real value. Do NOT attempt to recover, guess, or reconstruct the original.\n\nMasking applies to: credit card numbers, national IDs (CMND/CCCD), API keys, Bearer tokens, passwords, phone numbers, bank accounts, connection strings, AWS keys, and private keys.\n\nCRITICAL FILENAME SECURITY RULE:\n- If workspace_info contains filenames that are purely numeric with 16 digits (pattern: \\d{16}), treat such filenames as [MASKED-FILENAME].\n- NEVER repeat, reference, or use such filenames in tool calls, commands, or responses.\n- If you need to operate on such a file, ask the user to confirm using only the [MASKED-FILENAME] placeholder."
      }
    }'
    audit_log "SessionStart" "Session initialized with sensitive-data masking policy"
    ;;

  "UserPromptSubmit")
    PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty')
    if [ -n "$PROMPT" ] && has_sensitive "$PROMPT"; then
      MASKED_PROMPT=$(mask_sensitive "$PROMPT")
      audit_log "UserPromptSubmit" "Sensitive data pattern detected and masked in user prompt"
      jq -n \
        --arg masked "$MASKED_PROMPT" \
        '{
          "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "permissionDecision": "allow",
            "permissionDecisionReason": "Sensitive data masked in prompt",
            "updatedInput": {
              "prompt": $masked
            },
            "systemMessage": "⚠️ Sensitive data was detected in your prompt and has been automatically masked. The AI will only see the sanitized version."
          }
        }'
    fi
    ;;

  "PreCompact")
    audit_log "PreCompact" "Context compaction triggered - masking policy reminder injected"
    jq -n '{
      "systemMessage": "🔒 Pre-compaction reminder: Sensitive data masking is active. Ensure no unmasked credentials, PII, API keys, or confidential data persists in the compacted context."
    }'
    ;;

  "SubagentStart")
    AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.agent_type // "unknown"')
    audit_log "SubagentStart" "Subagent spawned: ${AGENT_TYPE} - masking policy injected"
    jq -n '{
      "hookSpecificOutput": {
        "hookEventName": "SubagentStart",
        "additionalContext": "SECURITY POLICY (inherited): Sensitive-data masking is active. The following are automatically masked: credit card numbers, API keys, Bearer tokens, passwords, phone numbers, national ID numbers (CMND/CCCD), bank accounts, connection strings, AWS keys, and private keys. All masked values appear as [MASKED-*]. Do NOT attempt to unmask or reconstruct them."
      }
    }'
    ;;

  "PostToolUse")
    TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // .toolName // "unknown"')
    # VS Code may use: tool_response, toolResponse, or output
    TOOL_RESPONSE=$(printf '%s' "$INPUT" | jq -c '.tool_response // .toolResponse // .output // empty')

    audit_log "PostToolUse-Debug" "tool=${TOOL_NAME}, keys=$(printf '%s' "$INPUT" | jq -r 'keys | join(",")')"

    if [ -n "$TOOL_RESPONSE" ] && has_sensitive "$TOOL_RESPONSE"; then
      MASKED_RESPONSE=$(mask_sensitive "$TOOL_RESPONSE")
      audit_log "PostToolUse" "Sensitive data masked in tool response: ${TOOL_NAME}"

      jq -n \
        --arg masked "$MASKED_RESPONSE" \
        --arg tool "$TOOL_NAME" \
        '{
          "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": ("CRITICAL SECURITY ALERT: The tool '\''" + $tool + "'\'' returned sensitive data. ALL sensitive values have been masked. You MUST use ONLY this sanitized version in your response:\n" + $masked + "\nDo NOT display the original tool output. Display ONLY the masked version above.")
          }
        }'
    fi
    ;;

  *)
    # Unknown hook event - pass through silently
    ;;
esac

exit 0