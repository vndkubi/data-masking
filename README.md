# mask-data

A sensitive data masking system for GitHub Copilot AI sessions. Prevents the AI agent from seeing raw sensitive values — credit card numbers, API keys, national IDs, and more — by intercepting and replacing them with `[MASKED-*]` placeholders before they reach the model.

Supports **Linux**, **macOS**, and **WSL** (Windows Subsystem for Linux).

---

## How it works

Two layers of protection run together:

**1. File renaming (invoke-mask / invoke-restore)**
Files whose names are purely numeric (9–16 digits, e.g. a card number used as a filename) are temporarily renamed to `masked-<hash>.<ext>` before a Copilot session starts. The original names are stored in a local mapping file and restored when the session ends.

**2. Content masking hooks**
Copilot agent hooks intercept every relevant event (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PreCompact`, `SubagentStart`) and scan the payload for sensitive patterns. Any match is replaced with a typed placeholder before the data is passed to the model.

| Sensitive type | Placeholder |
|---|---|
| Credit card number | `[MASKED-CC]` |
| API / secret key | `prefix-[MASKED-KEY]` |
| Bearer token | `Bearer [MASKED-TOKEN]` |
| Credentials in key-value pairs | `[MASKED-PASS]` |
| AWS access key | `[MASKED-AWS-KEY]` |
| Vietnamese phone number | `[MASKED-PHONE]` |
| CMND (national ID) | `[MASKED-ID]` |
| CCCD (citizen ID) | `[MASKED-CCCD]` |
| Bank account number | `[MASKED-BANK-ACC]` |
| CVV / CVC field | `[MASKED-CVV]` |
| Private key block | `[MASKED-PRIVATE-KEY]` |

---

## Project structure

```
.github/
  copilot-instructions.md         # AI policy — enforces masked-only rules in every session
  hooks/
    masking-config.json           # Regex patterns for each sensitive data type
    sensitive-data-mask.json      # Hook event wiring (which events trigger masking)
    scripts/
      mask-sensitive-data.sh      # Hook script (Linux / macOS / WSL)
      mask-sensitive-data.ps1     # Hook script (Windows native / PowerShell — invoke-* only)
    logs/
      hook-debug.log              # Diagnostic log written by the hook scripts
scripts/
  invoke-mask.sh                  # Rename sensitive filenames before session (Linux/macOS/WSL)
  invoke-mask.ps1                 # Rename sensitive filenames before session (Windows)
  invoke-restore.sh               # Restore original filenames after session (Linux/macOS/WSL)
  invoke-restore.ps1              # Restore original filenames after session (Windows)
  verify-mask-sensitive-data.sh   # Verify masking works correctly on a given file
data/
  data-sample.json                # Example file with sensitive fields (masked at rest)
wiremock/
  test1/masked-*.json             # WireMock stubs with originally sensitive filenames
  test2/masked-*.json
logs/                             # Runtime audit logs
```

---

## Requirements

| Platform | Requirements |
|---|---|
| Linux / macOS / WSL | Bash 4+, `jq`, `perl`, `shasum` or `sha1sum` |
| Windows (invoke-\* scripts only) | PowerShell 5.1 or 7+ |
| Git operations | Git must be on `PATH` |

Install `jq` if missing:

```bash
# Ubuntu / WSL
sudo apt-get install -y jq

# macOS
brew install jq
```

---

## Installation

### Per-repository

Copy the hook files into your project and register them with VS Code Copilot.

**Step 1 — Copy files**

```bash
# From within your project root
cp -r /path/to/mask-data/.github .
cp -r /path/to/mask-data/scripts .
```

Or clone just the relevant files manually:

```
your-project/
  .github/
    copilot-instructions.md
    hooks/
      masking-config.json
      sensitive-data-mask.json
      scripts/
        mask-sensitive-data.sh
```

**Step 2 — Make script executable**

```bash
chmod +x .github/hooks/scripts/mask-sensitive-data.sh
```

**Step 3 — Register hooks in VS Code**

VS Code Copilot automatically discovers hook files from `.github/hooks/*.json` in the workspace root. No further configuration is needed — opening the project in VS Code activates the hooks.

To verify discovery, open the VS Code Output panel → **GitHub Copilot Chat** and start a new session. The `SessionStart` hook will fire and inject the masking policy into the AI context.

---

### Global (all repositories)

Apply masking to every Copilot session on your machine, regardless of which project is open.

**Step 1 — Create the global hooks directory and copy scripts**

```bash
mkdir -p ~/.copilot/hooks/scripts

# Copy the hook script
cp /path/to/mask-data/.github/hooks/scripts/mask-sensitive-data.sh \
   ~/.copilot/hooks/scripts/

# Copy the masking config
cp /path/to/mask-data/.github/hooks/masking-config.json \
   ~/.copilot/hooks/

chmod +x ~/.copilot/hooks/scripts/mask-sensitive-data.sh
```

**Step 2 — Create the global hook wiring file**

Create `~/.copilot/hooks/global-mask.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "type": "command",
        "command": "bash ~/.copilot/hooks/scripts/mask-sensitive-data.sh",
        "linux": "bash ~/.copilot/hooks/scripts/mask-sensitive-data.sh",
        "osx":   "bash ~/.copilot/hooks/scripts/mask-sensitive-data.sh",
        "timeout": 15
      }
    ],
    "UserPromptSubmit": [
      {
        "type": "command",
        "command": "bash ~/.copilot/hooks/scripts/mask-sensitive-data.sh",
        "linux": "bash ~/.copilot/hooks/scripts/mask-sensitive-data.sh",
        "osx":   "bash ~/.copilot/hooks/scripts/mask-sensitive-data.sh",
        "timeout": 15
      }
    ],
    "PreToolUse": [
      {
        "type": "command",
        "command": "bash ~/.copilot/hooks/scripts/mask-sensitive-data.sh",
        "linux": "bash ~/.copilot/hooks/scripts/mask-sensitive-data.sh",
        "osx":   "bash ~/.copilot/hooks/scripts/mask-sensitive-data.sh",
        "timeout": 15
      }
    ],
    "PostToolUse": [
      {
        "type": "command",
        "command": "bash ~/.copilot/hooks/scripts/mask-sensitive-data.sh",
        "linux": "bash ~/.copilot/hooks/scripts/mask-sensitive-data.sh",
        "osx":   "bash ~/.copilot/hooks/scripts/mask-sensitive-data.sh",
        "timeout": 15
      }
    ],
    "PreCompact": [
      {
        "type": "command",
        "command": "bash ~/.copilot/hooks/scripts/mask-sensitive-data.sh",
        "linux": "bash ~/.copilot/hooks/scripts/mask-sensitive-data.sh",
        "osx":   "bash ~/.copilot/hooks/scripts/mask-sensitive-data.sh",
        "timeout": 15
      }
    ],
    "SubagentStart": [
      {
        "type": "command",
        "command": "bash ~/.copilot/hooks/scripts/mask-sensitive-data.sh",
        "linux": "bash ~/.copilot/hooks/scripts/mask-sensitive-data.sh",
        "osx":   "bash ~/.copilot/hooks/scripts/mask-sensitive-data.sh",
        "timeout": 15
      }
    ]
  }
}
```

> **Note:** The global hook script reads `masking-config.json` from the **project's** `.github/hooks/` directory (via the `cwd` field in the hook payload). If the project has no local config, the hook exits silently without masking. To apply masking in all projects without a local config, the script falls through to its built-in defaults for digit patterns — but for full pattern coverage a local `masking-config.json` is recommended.

**Step 3 — Hook priority**

VS Code Copilot merges hooks from all discovered locations. If a project also has `.github/hooks/sensitive-data-mask.json`, both the global and per-project hooks fire. This is additive — not a conflict.

---

## Usage

### Before a Copilot session

Rename any file whose name is a sensitive number:

```bash
# Linux / macOS / WSL
bash scripts/invoke-mask.sh

# Windows
.\scripts\invoke-mask.ps1
```

The script will:
- Find all files with purely numeric names (9–16 digits)
- Rename them to `masked-<sha1-hash>.<ext>`
- Save the mapping to `.github/hooks/.masked-files.json`
- Mark the originals with `git update-index --skip-worktree` so Git ignores the rename

### After a Copilot session

Restore the original filenames:

```bash
# Linux / macOS / WSL
bash scripts/invoke-restore.sh

# Windows
.\scripts\invoke-restore.ps1
```

### Targeting a specific directory

Both scripts accept an optional workspace root argument:

```bash
bash scripts/invoke-mask.sh /path/to/project

.\scripts\invoke-mask.ps1 -WorkspaceRoot "C:\path\to\project"
```

### Verify masking on a file

Test that the hook script correctly masks a file's contents before committing it to a session:

```bash
bash scripts/verify-mask-sensitive-data.sh data/0123456789123456.json

# WSL with Windows path
bash scripts/verify-mask-sensitive-data.sh 'D:\Personal\Projects\mask-data\data\0123456789123456.json'
```

Output shows the original content, the masked version, and a line-by-line diff of what changed.

---

## Masking patterns

Patterns are configured in [.github/hooks/masking-config.json](.github/hooks/masking-config.json). Each entry defines:

| Field | Description |
|---|---|
| `name` | Human-readable label |
| `regex` | Pattern to match (used by both PowerShell and Bash) |
| `regexBash` | Optional Bash-specific override (e.g. to avoid PCRE syntax unsupported by GNU sed) |
| `replacement` | Placeholder string (supports `\1` backreferences) |

Built-in patterns cover:

- Credit cards (16-digit and formatted `XXXX-XXXX-XXXX-XXXX`)
- AWS access keys (`AKIA…`)
- Generic API / secret keys (`sk-`, `pk-`, `api-`, `token-`, `key-` prefixes)
- Bearer tokens
- Database connection strings (MongoDB, PostgreSQL, MySQL, Redis)
- Credential key-value pairs (`passwd`, `pwd`, `secret`, `pass` style assignments)
- Vietnamese national IDs (CMND 9-digit, CCCD 12-digit)
- Bank account numbers (10–14 digits)
- Vietnamese phone numbers (`+84` / `0xx`)
- CVV / CVC fields
- Private keys / certificates (PEM blocks)

### Adding custom patterns

Add an entry to the `customPatterns` array in `masking-config.json`:

```json
"customPatterns": [
  {
    "name": "My Token",
    "regex": "(?i)MyToken_[a-zA-Z0-9]{15,}",
    "replacement": "[MASKED-MY-TOKEN]"
  }
]
```

---

## Hook events

The masking script is triggered on every hook event listed in [.github/hooks/sensitive-data-mask.json](.github/hooks/sensitive-data-mask.json):

| Event | When it fires | What it does |
|---|---|---|
| `SessionStart` | Agent session initialises | Injects masking policy into the AI system context |
| `UserPromptSubmit` | User submits a prompt | Scans and masks sensitive data in the prompt text |
| `PreToolUse` | Before any tool call | Masks tool arguments; blocks file reads with sensitive paths; asks for confirmation before sending sensitive data to external tools |
| `PostToolUse` | After any tool call | Masks sensitive data returned in tool results |
| `PreCompact` | Before context compaction | Reminds the AI to carry only masked values into the compacted context |
| `SubagentStart` | Before a sub-agent is spawned | Injects masking policy into the sub-agent context |

---

## Security rules enforced by the AI

The [.github/copilot-instructions.md](.github/copilot-instructions.md) instructs the AI to:

1. **Never reconstruct** original values from masked placeholders.
2. **Only use masked versions** when passing data to any tool, external service, MCP server, or API.
3. **Only store masked versions** in memory, session notes, or sub-agent hand-offs.
4. **Treat `[MASKED-*]` as the real value** — do not attempt to recover the original.
5. **Never reference** filenames that are purely numeric (9–16 digits).

---

## Audit logging

The hook scripts write to two log files:

| File | Contents |
|---|---|
| `logs/copilot-mask-audit.log` | Audit trail of every masking event (event type, tool name, action taken) |
| `.github/hooks/logs/hook-debug.log` | Low-level diagnostic log (script invocation, raw JSON payloads, config path resolution) |

Neither log file ever records the original sensitive values — only event metadata and masked placeholders.

---

## Limitations

### Regex-based detection only
Masking relies entirely on regular expressions. Sensitive data in unusual formats, obfuscated strings, or values split across multiple lines may not be detected. There is no semantic understanding of what constitutes sensitive data in a given context.

### Hooks fire on content entering the hook pipeline — not on the AI's in-memory context
If sensitive data was introduced into the AI's context window before the hook fired (e.g. via an earlier tool call that was not intercepted, or content pasted directly into chat), that data is already in context and cannot be retroactively removed by subsequent hooks.

### File renaming (invoke-mask) is a manual step
The `invoke-mask` / `invoke-restore` scripts must be run manually before and after each session. There is no automatic trigger. If forgotten, files with numeric names remain visible to the AI.

### Content masking does not apply inside binary files
The hook scripts read file contents as plain text. Binary files (images, compiled artifacts, encrypted blobs) are not scanned and are passed through unchanged.

### No support for Windows native (hooks only)
The hook scripts (`mask-sensitive-data.sh`) require Bash and `jq`. They run on Linux, macOS, and WSL. On Windows native (without WSL), Copilot hooks will not execute. The `invoke-mask.ps1` / `invoke-restore.ps1` scripts for file renaming still work on Windows native.

### Pattern false positives on numeric sequences
The digit-range patterns (9-digit CMND, 12-digit CCCD, 10–14-digit bank accounts) can match innocent numeric sequences such as timestamps, version numbers, or IDs in log lines. Review the `masking-config.json` patterns and narrow them if false positives cause issues in your codebase.

### Global hooks require a per-project masking-config.json for full coverage
When using the global installation, the hook script resolves `masking-config.json` from the active project's `.github/hooks/` directory. Projects without this file will only receive basic built-in digit-pattern masking, not the full pattern set.

### IntelliJ / other IDEs not supported
VS Code Copilot hooks are a VS Code extension feature. GitHub Copilot in IntelliJ IDEA and other JetBrains IDEs does not support a hook API. This system has no effect in those environments.
