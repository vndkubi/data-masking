# mask-data

A sensitive data masking starter kit for GitHub Copilot AI sessions. It prevents the agent from seeing raw sensitive values by intercepting tool input and replacing matched text with `[MASKED-*]` placeholders before execution.

Supports **Windows**, **macOS**, and **WSL** for Copilot CLI hooks. Windows uses built-in Windows PowerShell 5.1; macOS and WSL use PowerShell 7 (`pwsh`).

---

## How it works

Two layers of protection run together:

**1. File renaming (invoke-mask / invoke-restore)**
Files whose names are purely numeric (9–16 digits, e.g. a card number used as a filename) are temporarily renamed to `masked-<hash>.<ext>` before a Copilot session starts. The original names are stored in a local mapping file and restored when the session ends.

**2. Content masking hooks**
Copilot agent hooks intercept CLI events (`SessionStart`, `PreToolUse`, `PreCompact`, `SubagentStart`) and scan the payload for sensitive patterns. Tool arguments can be denied, redirected to masked temporary files, or rewritten with typed placeholders before execution.

| Starter sample | Placeholder |
|---|---|
| Credit card number | `[MASKED-CC]` |
| API key | `[MASKED-KEY]` |
| Bearer token | `Bearer [MASKED-TOKEN]` |
| Password assignment | `[MASKED-PASS]` |
| Custom demo pattern | `[MASKED-CUSTOMER-ID]` |

---

## Project structure

```
.github/
  copilot-instructions.md         # AI policy — enforces masked-only rules in every session
  hooks/
    masking-config.json           # Starter regex patterns plus customPatterns examples
    sensitive-data-mask.json      # Hook event wiring (which events trigger masking)
cli/
  install.ps1                     # Auto setup for the Copilot CLI bundle
  validate-config.ps1             # Validate regex syntax, JSON shape, duplicate replacements
  preview-mask.ps1                # Preview masked output from a file or input string
  masking-config.json             # Strict JSON masking rules copied to ~/.copilot
  lib/
    mask-data-tools.ps1           # Shared config and masking helpers for local CLI tools
  hooks/
    sensitive-data-mask.json      # CLI hook event wiring
    scripts/
      mask-sensitive-data.ps1     # Shared masking engine
scripts/
  invoke-mask.sh                  # Rename sensitive filenames before session (Linux/macOS/WSL)
  invoke-mask.ps1                 # Rename sensitive filenames before session (Windows)
  invoke-restore.sh               # Restore original filenames after session (Linux/macOS/WSL)
  invoke-restore.ps1              # Restore original filenames after session (Windows)
  verify-mask-sensitive-data.sh   # Verify masking works correctly on a given file
data/
  data-sample.json                # Small example file with a few sample patterns
wiremock/
  test1/masked-*.json             # WireMock stubs with originally sensitive filenames
  test2/masked-*.json
logs/                             # Runtime audit logs (ignored)
```

---

## Requirements

| Platform | Requirements |
|---|---|
| Windows CLI hooks | Windows PowerShell 5.1 |
| macOS / WSL CLI hooks | PowerShell 7 (`pwsh`) |
| Legacy Bash helper scripts | Bash 4+, `jq`, `perl`, `shasum` or `sha1sum` |
| Git operations | Git must be on `PATH` |

The recommended CLI hook path does not require `jq`, `perl`, Git Bash, or WSL on Windows.

---

## Installation

### Per-repository

For Copilot CLI, keep the hook wiring and the PowerShell engine in the repository. This project is already wired this way through `.github/hooks/sensitive-data-mask.json`.

To copy the same setup into another repository:

```bash
# From within your project root
cp -r /path/to/mask-data/.github .
mkdir -p cli/hooks/scripts
cp /path/to/mask-data/cli/hooks/scripts/mask-sensitive-data.ps1 cli/hooks/scripts/
cp /path/to/mask-data/cli/masking-config.json cli/masking-config.json
cp -r /path/to/mask-data/scripts .
```

Or create these files manually:

```
your-project/
  .github/
    copilot-instructions.md
    hooks/
      masking-config.json
      sensitive-data-mask.json
  cli/
    masking-config.json
    hooks/
      scripts/
        mask-sensitive-data.ps1
```

Copilot CLI loads JSON hook files from `.github/hooks/*.json`. The repo-local hook uses Windows PowerShell 5.1 on Windows and `pwsh` on macOS/WSL.

---

### Global (all repositories)

Apply masking to every Copilot CLI session on your machine, regardless of which project is open.

```powershell
# Windows PowerShell 5.1
powershell -NoProfile -ExecutionPolicy Bypass -File .\cli\install.ps1

# macOS / WSL
pwsh ./cli/install.ps1
```

The installer creates `~/.copilot/masking-config.json`, `~/.copilot/hooks/sensitive-data-mask.json`, and `~/.copilot/hooks/scripts/mask-sensitive-data.ps1`.

Use `-CopilotHome "$HOME/.copilot-test"` to test the bundle in a separate directory. Existing target files are backed up unless `-NoBackup` is passed.

Run `.\cli\install.ps1 -Check` when you only want to validate the config before installing.

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

### Validate config

Validate JSON shape, regex syntax, and duplicate replacements before installing hooks:

```powershell
.\cli\validate-config.ps1
```

Use `-Strict` when warnings should fail the command:

```powershell
.\cli\validate-config.ps1 -Strict
```

### Preview masked output

Preview masking for a string:

```powershell
.\cli\preview-mask.ps1 -Text 'customer_id=CUST-123456 password=DemoPass123'
```

Preview masking for a file:

```powershell
.\cli\preview-mask.ps1 -FilePath .\data\data-sample.json
```

---

## Masking patterns

Patterns are configured in [.github/hooks/masking-config.json](.github/hooks/masking-config.json). Each entry defines:

| Field | Description |
|---|---|
| `name` | Human-readable label |
| `enabled` | Set to `false` to keep a rule in strict JSON without running it |
| `regex` | .NET regex pattern used by the PowerShell masking engine |
| `replacement` | Placeholder string (supports `\1` backreferences) |

The default config intentionally stays small. It ships with a few starter examples:

- Credit card numbers
- API keys
- Bearer tokens
- Password assignments
- One custom pattern sample in `customPatterns`

The expected workflow is to replace or extend these with your own regexes.

### Adding custom patterns

Add an entry to the `customPatterns` array in `masking-config.json`:

```json
"customPatterns": [
  {
    "name": "Order ID",
    "enabled": true,
    "regex": "(?i)(\"?order_id\"?\\s*[:=]\\s*\"?)ORD-\\d{8}",
    "replacement": "$1[MASKED-ORDER-ID]"
  }
]
```

---

## Hook events

The masking script is triggered on every hook event listed in [.github/hooks/sensitive-data-mask.json](.github/hooks/sensitive-data-mask.json):

| Event | When it fires | What it does |
|---|---|---|
| `SessionStart` | Agent session initialises | Injects masking policy into the AI system context |
| `PreToolUse` | Before any tool call | Masks tool arguments; blocks file reads with sensitive paths; asks for confirmation before sending sensitive data to external tools |
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

The hook scripts write runtime logs outside normal source control paths:

| File | Contents |
|---|---|
| `~/.copilot/logs/mask-sensitive-data.log` | CLI hook skip reasons and runtime diagnostics |
| `logs/` / `.github/hooks/logs/` | Legacy runtime logs, ignored by `.gitignore` |

Neither log file ever records the original sensitive values — only event metadata and masked placeholders.

---

## Inline suggestions

The hook system in this project applies **only to Copilot Chat and agent mode**. It has no effect on inline code completions (ghost text).

For inline suggestions, Copilot sends surrounding code context directly to GitHub servers — there is no client-side API to intercept or modify that payload before transmission.

### What you can do for inline suggestions

**Option 1 — Content Exclusions (recommended)**

Configure at the GitHub repository level: _Settings → Copilot → Content exclusion_. Files matching the patterns will be excluded from Copilot context for inline suggestions.

Example patterns to exclude files containing sensitive data:

```
*.env
**/.env*
**/secrets/**
**/credentials/**
data/*.json
wiremock/**
```

Content exclusions require a GitHub account. Repository-level exclusions can be set by repository admins. Organization-level exclusions require a Copilot Business or Enterprise plan.

**Option 2 — Disable inline suggestions per file type**

In `.vscode/settings.json` (or user settings):

```json
{
  "github.copilot.enable": {
    "*": true,
    "dotenv": false,
    "properties": false,
    "json": false
  }
}
```

**Option 3 — Rename sensitive files before opening VS Code**

The `invoke-mask` script renames files with numeric names before a session. If those files are not open in the editor, their content is not included in inline suggestion context.

### Coverage summary

| Feature | Copilot Chat / Agent | Inline Suggestions |
|---|---|---|
| Hook-based content masking | ✅ This project | ❌ No hook API |
| Content Exclusions (path-based) | — | ✅ GitHub Settings |
| Disable per file type | — | ✅ VS Code settings |
| File renaming (invoke-mask) | ✅ | ✅ |

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

### Runtime requirement differs by OS
Windows native uses Windows PowerShell 5.1. macOS and WSL require PowerShell 7 (`pwsh`) for the CLI hook engine.

### Pattern false positives
Any broad regex can mask data you did not intend to hide. Review the starter samples in `masking-config.json` and narrow or replace them for your real data shapes.

### Config lookup is first-match wins
The hook reads `MASK_DATA_CONFIG`, then workspace `.copilot/masking-config.json`, then workspace `.github/hooks/masking-config.json`, then global `~/.copilot/masking-config.json`. If the first existing file is invalid JSON, the hook skips and logs the reason instead of falling through.

### IntelliJ / other IDEs not supported
VS Code Copilot hooks are a VS Code extension feature. GitHub Copilot in IntelliJ IDEA and other JetBrains IDEs does not support a hook API. This system has no effect in those environments.
