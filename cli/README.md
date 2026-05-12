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
  "regex": "(?i)(\"?customer_id\"?\\s*[:=]\\s*\"?)CUST-\\d{6,}",
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
- `UserPromptSubmit`: best-effort masking hint for the prompt text only. It does not block the session.
- `PreToolUse`: the primary mutation and enforcement point. It asks, denies, redirects, or rewrites tool args when sensitive data is found.
- `PermissionRequest`: CLI-only best-effort advisory layer. It no longer denies for masking alone.
- `PostToolUse` and `PostToolUseFailure`: best-effort leak detection after tool execution. They add masked context but do not block for masking alone.
- `PreCompact`: emits a best-effort reminder before compaction.
- `SubagentStart`: emits the masking policy for spawned agents.
- `Stop` and `SubagentStop`: rescan the transcript and emit masked guidance without blocking completion.
- `SessionEnd`, `ErrorOccurred`, and `Notification`: provide cleanup, diagnostics, or additional masked context where supported.

The practical behavior split is:

1. `PreToolUse` can still rewrite hook-visible tool input and redirect reads to masked temp files.
2. Later events are advisory and best-effort only.
3. VS Code attachment contents can already be embedded into the initial model request before any mutable hook sees them.

That last point is a platform limitation: attached file content shown in VS Code debug logs under the initial `llm_request` is not currently interceptable by this hook bundle before it is sent upstream.
