# Copilot CLI Bundle

This is the portable CLI path for installing the masking hook into `~/.copilot`.

## Runtime model

- Windows: Windows PowerShell 5.1 via `powershell.exe`.
- macOS, Linux, WSL, and devcontainers: PowerShell 7 via `pwsh`.
- No `jq`, `perl`, Python, Git Bash, or WSL is required by the masking engine.

The hook wiring keeps separate shell commands for Unix and Windows:

- `bash`: calls `pwsh`.
- `powershell`: calls Windows PowerShell 5.1.

If you use a devcontainer, `pwsh` must exist inside the container image itself. A host-side Windows or WSL install does not help because the hook runs in the active container environment.

## Install

Run the installer from the repo root:

```powershell
# Windows PowerShell 5.1
powershell -NoProfile -ExecutionPolicy Bypass -File .\cli\install.ps1

# macOS / Linux / WSL
pwsh ./cli/install.ps1
```

The installer creates or updates:

```text
~/.copilot/
  masking-config.json
  hooks/
    sensitive-data-mask.json
    scripts/
      mask-sensitive-data.ps1
  logs/
```

Existing target files are backed up with a `.bak-YYYYMMDD-HHMMSS` suffix before they are overwritten. Use `-NoBackup` to skip backups:

```powershell
.\cli\install.ps1 -NoBackup
```

Use a custom target to test without touching the real Copilot directory:

```powershell
.\cli\install.ps1 -CopilotHome "$HOME/.copilot-test"
```

Validate the config without installing anything:

```powershell
.\cli\install.ps1 -Check
```

## Configuration

`masking-config.json` is strict JSON. The bundled file is intentionally small and only ships with a few starter samples plus one `customPatterns` example.

Do not comment out patterns. Disable a rule with:

```json
{
  "name": "Demo Customer ID",
  "enabled": false,
  "regex": "(?i)(\"?customer_id\"?\\s*[:=]\\s*\"?)CUST-\\d{6}",
  "replacement": "$1[MASKED-CUSTOMER-ID]"
}
```

Config lookup order at runtime:

1. `MASK_DATA_CONFIG`
2. `<workspace>/.copilot/masking-config.json`
3. `<workspace>/.github/hooks/masking-config.json`
4. `~/.copilot/masking-config.json`

The first existing file wins. If that file is invalid JSON or has no enabled patterns, the hook skips and writes the reason to `~/.copilot/logs/mask-sensitive-data.log`.

## Repo-local bundle

The repository also ships a self-contained `.github/hooks` bundle for per-repo usage. Use `cli/` when you want global install plus the local helper tools, and use `.github/hooks` when you want the hook to live with the repository.

## Local Tools

Validate regex syntax, JSON shape, and duplicate replacements before installing:

```powershell
.\cli\validate-config.ps1
```

Use `-Strict` when warnings such as duplicate replacements should fail the command:

```powershell
.\cli\validate-config.ps1 -Strict
```

Preview masking against a string:

```powershell
.\cli\preview-mask.ps1 -Text 'customer_id=CUST-123456 password=DemoPass123'
```

Preview masking against a file:

```powershell
.\cli\preview-mask.ps1 -FilePath .\data\data-sample.json
```

## Hook Behavior

- `SessionStart`: emits the masking policy context.
- `PreToolUse`: asks, denies, redirects, or rewrites tool args when sensitive data is found.
- `PreCompact`: emits a reminder to keep only masked placeholders.
- `SubagentStart`: emits the masking policy for spawned agents.

`UserPromptSubmit` is intentionally not wired for CLI because current Copilot CLI docs mark `userPromptSubmitted` output as not processed. Masking protection is therefore enforced at tool boundaries.
