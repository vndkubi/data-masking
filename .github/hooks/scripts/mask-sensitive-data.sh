#!/usr/bin/env bash
# =============================================================
# Sensitive Data Masker - Copilot Agent Hook
# Handles: SessionStart, UserPromptSubmit, PreToolUse,
#           PreCompact, SubagentStart
# Platforms: Linux, macOS, WSL (Windows Subsystem for Linux)
# =============================================================
set -e

# Early diagnostic breadcrumb
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIAG_DIR="$(dirname "$SCRIPT_DIR")/logs"
mkdir -p "$DIAG_DIR" 2>/dev/null || true
DIAG_FILE="$DIAG_DIR/hook-debug.log"
echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Script invoked, SCRIPT_DIR=$SCRIPT_DIR" >> "$DIAG_FILE" 2>/dev/null || true

# ==============================================================
# DEPENDENCY CHECK: jq is required
# ==============================================================
if ! command -v jq &>/dev/null; then
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ERROR: jq not found. Install it first:" >> "$DIAG_FILE" 2>/dev/null || true
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')]   Ubuntu/WSL: sudo apt-get install -y jq" >> "$DIAG_FILE" 2>/dev/null || true
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')]   macOS:      brew install jq" >> "$DIAG_FILE" 2>/dev/null || true
    exit 0
fi

# ==============================================================
# CROSS-PLATFORM HELPERS
# ==============================================================

# Convert Windows-style path (C:\foo\bar or C:/foo/bar) to Unix path.
# Handles both WSL (uses wslpath) and plain Git Bash (manual /c/ conversion).
to_unix_path() {
    local p="$1"
    if [[ "$p" =~ ^[A-Za-z]:[/\\] ]]; then
        if command -v wslpath &>/dev/null; then
            p=$(wslpath "$p" 2>/dev/null) || true
        else
            # Git Bash fallback: C:\foo -> /c/foo
            local drive="${p:0:1}"
            local rest="${p:2}"
            drive=$(printf '%s' "$drive" | tr '[:upper:]' '[:lower:]')
            rest="${rest//\\//}"
            p="/${drive}${rest}"
        fi
    fi
    printf '%s' "$p"
}

# Cross-platform case-insensitive sed substitute.
# GNU sed (Linux/WSL) supports the I flag; BSD sed (macOS) does not.
# Falls back to perl which is available on all target platforms.
_sed_replace() {
    local regex="$1"
    local replacement="$2"
    local content="$3"
    local out
    # Try GNU sed with I flag first
    out=$(printf '%s' "$content" | sed -E "s|${regex}|${replacement}|gI" 2>/dev/null) \
        && { printf '%s' "$out"; return; }
    # Fall back to perl (macOS, any platform)
    printf '%s' "$content" | perl -pe "s|${regex}|${replacement}|gi" 2>/dev/null \
        || printf '%s' "$content"
}

# Read stdin with error handling
INPUT=$(cat 2>/dev/null || true)

if [ -z "$INPUT" ]; then
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] STDIN EMPTY - no hook data received" >> "$DIAG_FILE" 2>/dev/null || true
    exit 0
fi

HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // .hookEventName // empty' 2>/dev/null)
if [ -z "$HOOK_EVENT" ]; then
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] JSON PARSE FAILED or no hookEventName" >> "$DIAG_FILE" 2>/dev/null || true
    exit 0
fi

echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Hook event: $HOOK_EVENT" >> "$DIAG_FILE" 2>/dev/null || true
echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Raw JSON: $INPUT" >> "$DIAG_FILE" 2>/dev/null || true

# ==============================================================
# CONFIGURATION
# ==============================================================
CWD=$(echo "$INPUT" | jq -r '.cwd // "."')
# Normalize path so WSL can handle Windows-style CWD (e.g. C:\Users\...)
CWD=$(to_unix_path "$CWD")
CONFIG_PATH="$CWD/.github/hooks/masking-config.json"
EXTERNAL_TOOLS_REGEX="^(search_web|fetch_webpage|mcp_.*|github_repo)$"

# Load config if exists
if [ -f "$CONFIG_PATH" ]; then
  # Parse external tools regex if overridden
  NEW_EXT_REGEX=$(jq -r '.externalToolsRegex // empty' "$CONFIG_PATH" 2>/dev/null || true)
  if [ -n "$NEW_EXT_REGEX" ]; then
    EXTERNAL_TOOLS_REGEX="$NEW_EXT_REGEX"
  fi
  # We will dynamically parse customPatterns later inside the functions to avoid massive env vars
fi

# ==============================================================
# MASKING PATTERNS
# Order matters: longer digit patterns first to avoid partial matches
# ==============================================================

mask_sensitive() {
  local content="$1"

  if [ -f "$CONFIG_PATH" ]; then
    # Apply built-in patterns from config
    local pattern_count
    pattern_count=$(jq '(.patterns // []) | length' "$CONFIG_PATH" 2>/dev/null || echo 0)
    for i in $(seq 0 $((pattern_count - 1))); do
      local regex regexBash replacement active_regex
      regexBash=$(jq -r ".patterns[$i].regexBash // empty" "$CONFIG_PATH" 2>/dev/null || true)
      regex=$(jq -r ".patterns[$i].regex // empty" "$CONFIG_PATH" 2>/dev/null || true)
      replacement=$(jq -r ".patterns[$i].replacement // .patterns[$i].name // empty" "$CONFIG_PATH" 2>/dev/null || true)
      active_regex="${regexBash:-$regex}"
      # Strip PCRE inline (?i) flag - case-insensitivity handled by _sed_replace
      active_regex=$(echo "$active_regex" | sed 's/(?i)//g')
      if [ -n "$active_regex" ] && [ -n "$replacement" ]; then
        content=$(_sed_replace "$active_regex" "$replacement" "$content")
      fi
    done

    # Apply custom patterns from config
    local cpattern_count
    cpattern_count=$(jq '(.customPatterns // []) | length' "$CONFIG_PATH" 2>/dev/null || echo 0)
    for i in $(seq 0 $((cpattern_count - 1))); do
      local cregex cname
      cregex=$(jq -r ".customPatterns[$i].regex // empty" "$CONFIG_PATH" 2>/dev/null || true)
      cname=$(jq -r ".customPatterns[$i].replacement // .customPatterns[$i].name // empty" "$CONFIG_PATH" 2>/dev/null || true)
      cregex=$(echo "$cregex" | sed 's/(?i)//g')
      if [ -n "$cregex" ] && [ -n "$cname" ]; then
        content=$(_sed_replace "$cregex" "$cname" "$content")
      fi
    done
  fi

  echo "$content"
}

# Quick check if content likely contains sensitive patterns
has_sensitive() {
  local content="$1"
  local combined_regex=""

  if [ -f "$CONFIG_PATH" ]; then
    combined_regex=$(jq -r '[(.patterns // [])[].regex, (.customPatterns // [])[].regex] | map(select(. != null and . != "")) | join("|")' "$CONFIG_PATH" 2>/dev/null \
      | sed 's/(?i)//g' || true)
  fi

  if [ -n "$combined_regex" ]; then
    echo "$content" | grep -qiE "$combined_regex" 2>/dev/null
  else
    # Fallback if config is unavailable
    echo "$content" | grep -qiE '[0-9]{16}|[0-9]{12}|[0-9]{9}|AKIA[0-9A-Z]{16}' 2>/dev/null
  fi
}

# ==============================================================
# AUDIT LOG (append-only, no sensitive data in log)
# ==============================================================
audit_log() {
  local event="$1"
  local detail="$2"
  local log_dir
  log_dir="$(echo "$INPUT" | jq -r '.cwd // "."')/logs"
  mkdir -p "$log_dir" 2>/dev/null || true
  local log_file="$log_dir/copilot-mask-audit.log"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [${event}] ${detail}" >> "$log_file" 2>/dev/null || true
}

# ==============================================================
# DISPATCH BY HOOK EVENT
# ==============================================================

case "$HOOK_EVENT" in

  "PreToolUse")
    TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // .toolName // "unknown"')

    # Extract tool input (VS Code may use: input, toolInput, tool_input, or toolArgs)
    TOOL_INPUT_STR=$(echo "$INPUT" | jq -c '.tool_input // .toolInput // .input // .toolArgs // {}')

    audit_log "PreToolUse-Debug" "tool=${TOOL_NAME}, keys=$(echo "$INPUT" | jq -r 'keys | join(",")')"

    if [ -n "$TOOL_INPUT_STR" ] && [ "$TOOL_INPUT_STR" != "{}" ] && [ "$TOOL_INPUT_STR" != "null" ]; then

      # --- Egress Protection: ASK user before sending sensitive data to external tools ---
      if echo "$TOOL_NAME" | grep -qiE "$EXTERNAL_TOOLS_REGEX" 2>/dev/null; then
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
      [ -z "$_path_regex" ] && _path_regex='[0-9]{16}|[0-9]{12}|[0-9]{9}'
      audit_log "Strategy1-Debug" "tool=${TOOL_NAME} | regex_built=$([ -n '$_path_regex' ] && echo 'yes' || echo 'no') | input_len=${#TOOL_INPUT_STR} | checking..."
      if echo "$TOOL_INPUT_STR" | grep -qiE "(filePath|file_path|path|file)[^}]*(${_path_regex})"; then
        audit_log "PreToolUse" "DENIED: File path with sensitive pattern in tool: ${TOOL_NAME} | matched_input=$(echo "$TOOL_INPUT_STR" | grep -oiE '(filePath|file_path|path)[^,}]*' | head -1)"
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
        FILE_PATH=$(echo "$TOOL_INPUT_STR" | jq -r '.filePath // .file_path // .path // empty')
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

        UPDATED_INPUT=$(echo "$MASKED_STR" | jq '.' 2>/dev/null || echo "$MASKED_STR")

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
        "additionalContext": "SECURITY POLICY ACTIVE - SENSITIVE DATA MASKING:\nSensitive data in this session has been automatically masked with [MASKED-*] placeholders.\n\nRULES:\n1. Always use the masked placeholder (e.g. [MASKED-CC], [MASKED-KEY], [MASKED-ID]) when referencing sensitive values - never reconstruct or reveal the originals.\n2. When passing data to ANY tool call, external service, MCP tool, or API - use ONLY the masked version.\n3. When storing or summarising information into context (memory, compaction, subagent hand-off) - use ONLY the masked version.\n4. If you receive a [MASKED-*] value, treat it as the real value. Do NOT attempt to recover, guess, or reconstruct the original.\n\nMasking applies to: credit card numbers, national IDs (CMND/CCCD), API keys, Bearer tokens, passwords, phone numbers, bank accounts, connection strings, AWS keys, and private keys.\n\nCRITICAL FILENAME SECURITY RULE:\n- If workspace_info contains filenames that are purely numeric with 9-16 digits (pattern: \\d{9,16}), treat such filenames as [MASKED-FILENAME].\n- NEVER repeat, reference, or use such filenames in tool calls, commands, or responses.\n- If you need to operate on such a file, ask the user to confirm using only the [MASKED-FILENAME] placeholder."
      }
    }'
    audit_log "SessionStart" "Session initialized with sensitive-data masking policy"
    ;;

  "UserPromptSubmit")
    PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty')
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
    AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // "unknown"')
    audit_log "SubagentStart" "Subagent spawned: ${AGENT_TYPE} - masking policy injected"
    jq -n '{
      "hookSpecificOutput": {
        "hookEventName": "SubagentStart",
        "additionalContext": "SECURITY POLICY (inherited): Sensitive-data masking is active. The following are automatically masked: credit card numbers, API keys, Bearer tokens, passwords, phone numbers, national ID numbers (CMND/CCCD), bank accounts, connection strings, AWS keys, and private keys. All masked values appear as [MASKED-*]. Do NOT attempt to unmask or reconstruct them."
      }
    }'
    ;;

  "PostToolUse")
    TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // .toolName // "unknown"')
    # VS Code may use: tool_response, toolResponse, or output
    TOOL_RESPONSE=$(echo "$INPUT" | jq -c '.tool_response // .toolResponse // .output // empty')

    audit_log "PostToolUse-Debug" "tool=${TOOL_NAME}, keys=$(echo "$INPUT" | jq -r 'keys | join(",")')"

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