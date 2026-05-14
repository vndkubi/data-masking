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

`masking-config.json` is strict JSON. The bundled file ships mask-and-continue defaults for PCI/DSS account data, common PII, secrets, tokens, passwords, emails, SSNs, and customer IDs. Bundled patterns use `mask` enforcement so Copilot can keep working on payment projects while hook-visible sensitive values are replaced with placeholders.

Top-level policy controls:

- `externalToolsRegex`: tool names whose hook-visible inputs should be treated as outbound/external.
- `sensitiveFilenameRegex`: path/filename candidate matcher. The bundled config looks for 13-19 digit PAN candidates anywhere in the path.
- `sensitiveFilenameValidator`: optional extra check for `sensitiveFilenameRegex`. The bundled config uses `luhn`, so numeric filenames are treated as sensitive only when the candidate looks like a payment card PAN.
- `denyPathRegex`: optional file path deny policy. The bundled CLI config leaves this empty so read tools can be redirected to masked temp files instead of being denied.
- `denyShellCommandRegex`: shell commands denied before execution because they can upload raw local files or exfiltrate data outside the masking flow, such as `curl --data-binary @file`, `scp`, `aws s3`, and gist upload commands.

Pattern-level controls:

- `regex`: candidate matcher.
- `validator`: optional extra check before a regex candidate is considered sensitive. The bundled PAN pattern uses `validator: "luhn"` so long numeric IDs are not masked unless they pass the payment-card checksum.
- `replacement`: placeholder used for masking.

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

Per-pattern enforcement controls the hook response at each step:

```json
{
  "name": "Password Assignment",
  "enabled": true,
  "regex": "(?i)\\b(password|passwd|secret|pwd)\\b\\s*[:=]\\s*[^,\\s\"'}]{4,}",
  "replacement": "$1=[MASKED-PASS]",
  "enforcement": {
    "UserPromptSubmit": "mask",
    "PreToolUse": "mask"
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

When multiple patterns match in the same event, the most restrictive configured action wins. If `enforcement` is omitted, the current replace-only default stays in effect. The bundled PCI/DSS mode intentionally uses `mask` rather than `stop`, `deny`, `interrupt`, or `block` for normal prompt, tool, permission, and post-tool flows.

The PAN rule is intentionally two-stage: regex finds 13-19 digit candidates, then Luhn validation decides whether to mask. This avoids masking most long numeric IDs, but it is still a heuristic because some non-card IDs can pass Luhn by chance.

Avoid using PANs as mock-data filenames when possible. Prefer safe aliases such as `visa-valid-01.json` and put test PANs inside the file content. If a repository already has PAN-like filenames, use file-read tools rather than arbitrary shell commands: `read_file` and `view` can be redirected to a masked temp path, while shell commands that list or pass filenames may expose only masked aliases that are not reusable paths.

## Hook Behavior

- `SessionStart`: emits the masking policy context.
- `UserPromptSubmit`: scans the prompt text only. Bundled sensitive patterns configure `mask`, so the prompt is not stopped; the hook emits a masked advisory preview.
- `PreToolUse`: the primary masking point. File-read tools are redirected to masked temporary copies when matching content is detected. Shell tools such as `bash`, `powershell`, `run_in_terminal`, `runInTerminal`, and `terminal` are wrapped through `mask-command-output.ps1` so stdout/stderr is masked before returning to the model. Commands matching `denyShellCommandRegex` are denied because they can send raw local files outside the hook-visible output path.
- `PermissionRequest`: CLI-only advisory layer. Bundled sensitive patterns configure `mask`, so permission payloads are not denied by pattern matches.
- `PostToolUse` and `PostToolUseFailure`: leak detection after tool execution. Bundled sensitive patterns configure `mask`, so the hook emits masked additional context instead of blocking. For file-read tools such as `read_file` and `view`, the hook can re-check the requested file path when the `PostToolUse` payload does not include the tool result body.
- `PreCompact`: emits a best-effort reminder before compaction.
- `SubagentStart`: emits the masking policy for spawned agents.
- `Stop` and `SubagentStop`: rescan the transcript and emit masked guidance by default; a matched pattern can optionally configure `block`.
- `SessionEnd`, `ErrorOccurred`, and `Notification`: provide cleanup, diagnostics, or additional masked context where supported.

The practical behavior split is:

1. `PreToolUse` can still rewrite hook-visible tool input and redirect reads to masked temp files.
2. Shell command policy denies known raw file upload/exfiltration commands before execution. This is a regex guardrail, not a full DLP engine; extend `denyShellCommandRegex` for your environment.
3. `PostToolUse` is later and therefore less reliable for prevention; keep sensitive reads on tools that `PreToolUse` can redirect or shell commands whose stdout/stderr wrapper can mask.
4. Later events are otherwise advisory and best-effort only.
5. VS Code attachment contents and extension-internal transcript/log fields can already be embedded or logged before any mutable hook sees them.

That last point is a platform limitation: this CLI bundle can harden hook-visible payloads, but it cannot fix VS Code extension behavior where raw prompt attachments or internal hook telemetry are captured before the hook can rewrite them.
