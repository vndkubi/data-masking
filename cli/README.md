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

For the PCI/DSS `workspaceMirror` mode, prefer installing with the active repository root so the generated hook has the correct `cwd` and can create stable `.copilot/masked-data` mirror paths:

```powershell
# Windows PowerShell 5.1
powershell -NoProfile -ExecutionPolicy Bypass -File .\cli\install.ps1 -WorkspaceRoot (Resolve-Path .)

# macOS / Linux / WSL
pwsh ./cli/install.ps1 -WorkspaceRoot "$(pwd)"
```

The installer creates or updates:

```text
~/.copilot/
  hooks/
    masking-config.json
    scripts/
      mask-sensitive-data.ps1
      mask-command-output.ps1
  logs/
```

Without `-WorkspaceRoot`, the installer also writes a global hook config at `~/.copilot/hooks/sensitive-data-mask.json`.

When `-WorkspaceRoot` is provided, the installer also creates or updates local workspace files:

```text
<workspace>/.copilot/
  hooks/
    masking-config.json
    sensitive-data-mask.json
  masked-data/
```

The workspace hook points at the globally installed script but sets `cwd` to the workspace root. This is the recommended setup for legacy PCI mock repositories because relative tool paths resolve correctly and masked mirror paths stay reusable for the agent. The generated workspace hook/config and `masked-data/` mirror are added to `.gitignore` unless `-NoWorkspaceGitignore` is used.

Existing target files are backed up with a `.bak-YYYYMMDD-HHMMSS` suffix before they are overwritten. Use `-NoBackup` to skip backups:

```powershell
.\cli\install.ps1 -NoBackup
```

Use a custom target to test without touching the real Copilot directory:

```powershell
.\cli\install.ps1 -CopilotHome "$HOME/.copilot-test"
.\cli\install.ps1 -CopilotHome "$HOME/.copilot-test" -WorkspaceRoot (Resolve-Path .)
```

For current VS Code hooks, prompt rewrite output is not consumed. Use fail-closed workspace install so matched raw prompts are blocked before the model request:

```powershell
.\cli\install.ps1 -WorkspaceRoot (Resolve-Path .) -VSCodePromptBlock
```

This adds `MASK_DATA_USER_PROMPT_UNSUPPORTED_MODE=block` to the generated hook config. The bundled config also sets `userPromptSubmitUnsupportedMode: "block"` so prompt matches fail closed unless you explicitly change that value.

Validate the config without installing anything:

```powershell
.\cli\install.ps1 -Check
```

## Configuration

`masking-config.json` is strict JSON. The bundled file ships strict defaults for PCI/DSS account data, common PII, secrets, tokens, passwords, emails, SSNs, and customer IDs. Bundled patterns use `mask` enforcement for hook-visible tool data, while unsupported prompt rewrite surfaces are blocked by `userPromptSubmitUnsupportedMode: "block"`.

Top-level policy controls:

- `externalToolsRegex`: tool names whose hook-visible inputs should be treated as outbound/external.
- `maskedPathMode`: masked read-path strategy. Use `workspaceMirror` for stable repo-local mirror paths, or `tempHash` for the older opaque temp-cache path.
- `maskedMirrorRoot`: workspace-relative or absolute mirror root used when `maskedPathMode` is `workspaceMirror`. The bundled config uses `.copilot/masked-data`.
- `sensitiveFilenameRegex`: path/filename candidate matcher. The bundled config looks for 13-19 digit PAN candidates anywhere in the path.
- `sensitiveFilenameValidator`: optional extra check for `sensitiveFilenameRegex`. The bundled config uses `luhn`, so numeric filenames are treated as sensitive only when the candidate looks like a payment card PAN.
- `denyPathRegex`: file path deny policy for obvious secrets, exports, dumps, logs, and key material. File reads matching this policy are denied before content is read.
- `blockedPaths`: fixed or wildcard file/directory paths that Copilot must not access. Relative entries resolve under the active workspace root. Matching file-tool paths are denied before execution, and shell commands that visibly reference a blocked path are denied as a guardrail.
- `denyShellCommandRegex`: shell commands denied before execution because they can upload raw local files or exfiltrate data outside the masking flow, including outbound URLs, upload tools, remote cloud/SCM CLIs, sensitive file references, and common interpreter network APIs.
- `userPromptSubmitUnsupportedMode`: fallback for consumers that ignore `modifiedPrompt`. The bundled config uses `block` to stop matched prompts instead of sending raw `<userRequest>`.

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

Block fixed paths and wildcard path groups with:

```json
{
  "blockedPaths": [
    "secrets",
    "folder-security/**",
    "**/private/**",
    "D:/etc/**",
    "//folder-security/**",
    "//server/share/folder-security/**",
    "D:\\Personal\\Sensitive",
    "C:\\Users\\xxx\\.ssh"
  ]
}
```

The examples above block attempts such as `read_file D:/etc/app.env`, `read_file //folder-security/customer.csv`, `Get-Content folder-security/token.txt`, and any workspace path under a `private` directory. Prefer forward slashes in config values when possible; JSON backslashes must be escaped.

Config lookup order at runtime:

1. `MASK_DATA_CONFIG`
2. `<workspace>/.copilot/hooks/masking-config.json`
3. `<workspace>/.copilot/masking-config.json`
4. `<workspace>/.github/hooks/masking-config.json`
5. `<hook-folder>/masking-config.json`
6. `~/.copilot/masking-config.json` legacy fallback

The first existing file wins. If that file is invalid JSON, missing, or has no enabled patterns, the hook fails closed and writes the reason to `~/.copilot/logs/mask-sensitive-data.log`.

## Repo-local bundle

The repository also ships a `.github/hooks` launcher bundle for per-repo usage. It keeps repo-local hook config in `.github/hooks` and launches the canonical implementation from `cli/hooks/scripts` so the masking logic does not fork into two copies.

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

Avoid using PANs as mock-data filenames when possible. Prefer safe aliases such as `visa-valid-01.json` and put test PANs inside the file content.

For legacy repositories with thousands of PAN-like mock filenames, do not bulk rename just to make Copilot usable. With `maskedPathMode: "workspaceMirror"`, file-read tools such as `read_file` and `view` are redirected to stable masked mirror paths under `.copilot/masked-data`. The mirror preserves the relative directory structure and replaces sensitive filename segments with safe aliases plus a short hash, for example:

```text
fixtures/cards/4111111111111111.json
-> .copilot/masked-data/fixtures/cards/[MASKED-PAN]-4247e268.json
```

This lets the agent reuse the redirected path without exposing the original PAN filename. Keep `.copilot/masked-data/` out of source control.

## Hook Behavior

- `SessionStart`: emits the masking policy context.
- `UserPromptSubmit`: scans the prompt text only. Bundled sensitive patterns configure `mask`, and the bundled top-level prompt fallback blocks matched prompts on surfaces such as current VS Code hooks that ignore `modifiedPrompt`.
- `PreToolUse`: the primary masking point. File-read tools are redirected to stable masked mirror copies when matching content or sensitive filenames are detected. Blocked paths and denied path patterns are rejected before content is read. Shell tools such as `bash`, `powershell`, `run_in_terminal`, `runInTerminal`, and `terminal` are wrapped through `mask-command-output.ps1` only after the shell command passes the exfiltration policy.
- `PermissionRequest`: CLI-only advisory layer. Bundled sensitive patterns configure `mask`, so permission payloads are not denied by pattern matches.
- `PostToolUse` and `PostToolUseFailure`: leak detection after tool execution. Bundled sensitive patterns configure `mask`, so the hook emits masked additional context instead of blocking. For file-read tools such as `read_file` and `view`, the hook can re-check the requested file path when the `PostToolUse` payload does not include the tool result body.
- `PreCompact`: emits a best-effort reminder before compaction.
- `SubagentStart`: emits the masking policy for spawned agents.
- `Stop` and `SubagentStop`: rescan the transcript and emit masked guidance by default; a matched pattern can optionally configure `block`.
- `SessionEnd`, `ErrorOccurred`, and `Notification`: provide cleanup, diagnostics, or additional masked context where supported.

The practical behavior split is:

1. `PreToolUse` can still rewrite hook-visible tool input and redirect reads to masked mirror files.
2. Shell command policy denies known raw file upload/exfiltration commands before execution. This is a regex guardrail, not a full DLP engine; keep OS/container egress controls enabled for high-trust repositories.
3. `PostToolUse` is later and therefore less reliable for prevention; keep sensitive reads on tools that `PreToolUse` can redirect or shell commands whose stdout/stderr wrapper can mask.
4. Later events are otherwise advisory and best-effort only.
5. Copilot SDK supports `modifiedPrompt`; Copilot CLI currently documents `userPromptSubmitted` output as not processed, and VS Code documents `UserPromptSubmit` as common-output-only. For those surfaces, prompt masking is best-effort/advisory unless `-VSCodePromptBlock`, `userPromptSubmitUnsupportedMode: "block"`, or per-pattern `UserPromptSubmit: "stop"` is active.
6. VS Code attachment contents and extension-internal transcript/log fields can already be embedded or logged before any mutable hook sees them.

That last point is a platform limitation: this CLI bundle can harden hook-visible payloads, but it cannot fix VS Code extension behavior where raw prompt attachments or internal hook telemetry are captured before the hook can rewrite them.
