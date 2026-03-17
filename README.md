# mask-data

A sensitive data masking system for GitHub Copilot AI sessions. Prevents the AI agent from seeing raw sensitive values — credit card numbers, API keys, national IDs, and more — by intercepting and replacing them with `[MASKED-*]` placeholders before they reach the model.

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

## Project structure

```
.github/
  copilot-instructions.md       # AI policy — enforces masked-only rules
  hooks/
    masking-config.json         # Regex patterns for each sensitive data type
    sensitive-data-mask.json    # Hook event wiring (which events trigger masking)
    scripts/
      mask-sensitive-data.ps1   # Hook script (Windows / PowerShell)
      mask-sensitive-data.sh    # Hook script (macOS / Linux / Bash)
    logs/
      hook-debug.log            # Diagnostic log written by the hook scripts
scripts/
  invoke-mask.ps1               # Rename sensitive filenames before session (Windows)
  invoke-mask.sh                # Rename sensitive filenames before session (macOS/Linux)
  invoke-restore.ps1            # Restore original filenames after session (Windows)
  invoke-restore.sh             # Restore original filenames after session (macOS/Linux)
data/
  data-sample.json              # Example file with sensitive fields (masked at rest)
wiremock/
  test1/masked-*.json           # WireMock stubs with originally sensitive filenames
  test2/masked-*.json
logs/                           # Runtime audit logs
```

## Usage

### Before a Copilot session

Rename any file whose name is a sensitive number:

```powershell
# Windows
.\scripts\invoke-mask.ps1

# macOS / Linux
bash scripts/invoke-mask.sh
```

The script will:
- Find all files with purely numeric names (9–16 digits)
- Rename them to `masked-<sha1-hash>.<ext>`
- Save the mapping to `.github/hooks/.masked-files.json`
- Mark the originals with `git update-index --skip-worktree` so Git ignores the rename

### After a Copilot session

Restore the original filenames:

```powershell
# Windows
.\scripts\invoke-restore.ps1

# macOS / Linux
bash scripts/invoke-restore.sh
```

This reverses the renaming, removes the mapping file, and clears `skip-worktree` flags.

### Targeting a specific directory

Both scripts accept an optional workspace root argument:

```powershell
.\scripts\invoke-mask.ps1 -WorkspaceRoot "C:\path\to\project"
bash scripts/invoke-mask.sh /path/to/project
```

## Masking patterns

Patterns are configured in [.github/hooks/masking-config.json](.github/hooks/masking-config.json). Each entry defines:

| Field | Description |
|---|---|
| `name` | Human-readable label |
| `regex` | Pattern to match (PowerShell / .NET regex) |
| `regexBash` | Optional alternate pattern for the Bash script |
| `replacement` | Placeholder string (supports `\1` / `$1` backreferences) |

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

## Hook events

The masking script is triggered on every hook event listed in [.github/hooks/sensitive-data-mask.json](.github/hooks/sensitive-data-mask.json):

| Event | When it fires |
|---|---|
| `SessionStart` | Agent session initialises |
| `UserPromptSubmit` | User submits a prompt |
| `PreToolUse` | Before any tool call |
| `PostToolUse` | After any tool call (masks tool results) |
| `PreCompact` | Before context compaction |
| `SubagentStart` | Before a sub-agent is spawned |

## Security rules enforced by the AI

The [.github/copilot-instructions.md](.github/copilot-instructions.md) instructs the AI to:

1. **Never reconstruct** original values from masked placeholders.
2. **Only use masked versions** when passing data to any tool, external service, MCP server, or API.
3. **Only store masked versions** in memory, session notes, or sub-agent hand-offs.
4. **Treat `[MASKED-*]` as the real value** — do not attempt to recover the original.
5. **Never reference** filenames that are purely numeric (9–16 digits).

## Audit logging

The hook scripts write diagnostic output to `logs/copilot-mask-audit.log` (and `hook-debug.log` inside `.github/hooks/logs/`). Logs record which events fired, which tool calls were intercepted, and how many replacements were applied — without ever logging the original sensitive values.

## Requirements

| Platform | Requirement |
|---|---|
| Windows | PowerShell 5.1 or PowerShell 7+ |
| macOS / Linux | Bash 4+, `shasum` or `sha1sum` |
| Git operations | Git must be on `PATH` |
