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
      mask-command-output.ps1
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

`masking-config.json` is strict JSON. The bundled file is intentionally small and only ships with a few starter samples plus one `customPatterns` example. The bundled patterns stop `UserPromptSubmit` when a raw match is visible, so the user can resubmit with placeholders before the agent continues.

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

Optional enforcement can be attached to a pattern when you need a stronger response at a specific step:

```json
{
  "name": "Password Assignment",
  "enabled": true,
  "regex": "(?i)\\b(password|passwd|secret|pwd)\\b\\s*[:=]\\s*[^,\\s\"'}]{4,}",
  "replacement": "$1=[MASKED-PASS]",
  "enforcement": {
    "UserPromptSubmit": "stop",
    "PreToolUse": "deny"
  }
}
```

Supported enforcement actions:

- `UserPromptSubmit`: `mask`, `stop`
- `PreToolUse`: `mask`, `deny`
- `PermissionRequest`: `mask`, `deny`, `interrupt`
- `PostToolUse`: `mask`, `block`
- `Stop`: `mask`, `block`
- `SubagentStop`: `mask`, `block`

Meaning of the main control actions:

- `mask`: keep the current default behavior. The hook rewrites visible sensitive data to placeholders when it can, or emits masked advisory context when the event is already post-action.
- `stop`: stop the current user prompt before it continues. Use this at `UserPromptSubmit` when the prompt itself must not proceed.
- `deny`: deny a specific tool or permission step, but keep the overall chat session alive. Use this when the risky part is the tool action, not the whole conversation.
- `interrupt`: a stronger `PermissionRequest` deny. It denies the permission step and sets the interrupt flag so the agent flow is explicitly halted instead of quietly continuing.
- `block`: block a later-stage event such as `PostToolUse`, `Stop`, or `SubagentStop` after sensitive output has already been observed.

These actions are different because the hook API exposes different control surfaces at different stages. A prompt-submission hook can stop the request, a tool hook can deny that tool execution, and a permission hook can additionally interrupt the agent flow. There is no single universal action that means the same thing at every event.

When multiple patterns match in the same event, the most restrictive configured action wins. If `enforcement` is omitted, the current replace-only default stays in effect.

## Hook Behavior

- `SessionStart`: emits the masking policy context.
- `UserPromptSubmit`: by default it emits a best-effort masking hint for the prompt text only; the bundled patterns configure `stop` so raw prompt matches are blocked where the surface honors this output.
- `PreToolUse`: the primary mutation and enforcement point. By default it rewrites or redirects inputs; a matched pattern can optionally configure `deny`. File-read tools are redirected to masked temporary copies when matching content is detected. Shell tools such as `bash` and `powershell` are rewritten through `mask-command-output.ps1`, which runs the original command and masks stdout/stderr before the result is returned to the model.
- `PermissionRequest`: CLI-only advisory layer by default; a matched pattern can optionally configure `deny` or `interrupt`.
- `PostToolUse` and `PostToolUseFailure`: best-effort leak detection after tool execution. A matched pattern can optionally configure `block` for `PostToolUse`. For file-read tools such as `read_file` and `view`, the hook can re-check the requested file path when the `PostToolUse` payload does not include the tool result body.
- `PreCompact`: emits a best-effort reminder before compaction.
- `SubagentStart`: emits the masking policy for spawned agents.
- `Stop` and `SubagentStop`: rescan the transcript and emit masked guidance by default; a matched pattern can optionally configure `block`.
- `SessionEnd`, `ErrorOccurred`, and `Notification`: provide cleanup, diagnostics, or additional masked context where supported.

The practical behavior split is:

1. `PreToolUse` can still rewrite hook-visible tool input and redirect reads to masked temp files.
2. Shell output masking protects the model from hook-visible stdout/stderr, but it does not stop the command itself from sending data to a network service or another process. Use `PreToolUse: deny` or command policy for commands that can exfiltrate secrets.
3. `PostToolUse` is later and therefore less reliable for prevention; use `PreToolUse: deny` when the read itself must not happen.
4. Later events are otherwise advisory and best-effort only.
5. VS Code attachment contents can already be embedded into the initial model request before any mutable hook sees them.

That last point is a platform limitation: attached file content shown in VS Code debug logs under the initial `llm_request` is not currently interceptable by this hook bundle before it is sent upstream.
