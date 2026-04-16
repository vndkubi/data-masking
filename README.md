# mask-data

Email-first sensitive data masking demo for GitHub Copilot hooks.

This repository is set up as a simple hook-state demo for GitHub Copilot. Each hook step writes its sanitized input payload to a dedicated log file so you can present the flow clearly: `SessionStart -> UserPromptSubmit -> PreToolUse -> PostToolUse -> PreCompact -> SubagentStart`.

## What This Demo Covers

The hook wiring is split into one JSON file per event under `.github/hooks/` and runs on these events:

- `SessionStart`
- `UserPromptSubmit`
- `PreToolUse`
- `PostToolUse`
- `PreCompact`
- `SubagentStart`

The main demo goal is simple:

- Trigger one hook state
- Open the generated `logs/demo-*.json` file
- Explain what payload that hook receives
- Show that sensitive email values are sanitized to `[MASKED-EMAIL]`

## Active Demo Patterns

Configured in `.github/hooks/masking-config.json`:

- Email addresses -> `[MASKED-EMAIL]`
- Private key / certificate blocks -> `[MASKED-PRIVATE-KEY]`

You can extend the demo later by adding custom patterns to the same config file.

## Project Layout

```text
.github/
  copilot-instructions.md
  hooks/
    01-session-start.json
    02-user-prompt-submit.json
    03-pre-tool-use.json
    04-post-tool-use.json
    05-pre-compact.json
    06-subagent-start.json
    README.md
    masking-config.json
    scripts/
      01-session-start.sh
      01-session-start.ps1
      02-user-prompt-submit.sh
      02-user-prompt-submit.ps1
      03-pre-tool-use.sh
      03-pre-tool-use.ps1
      04-post-tool-use.sh
      04-post-tool-use.ps1
      05-pre-compact.sh
      05-pre-compact.ps1
      06-subagent-start.sh
      06-subagent-start.ps1
      hook-demo-common.sh
      HookDemoCommon.ps1
demo/
  README.md
  hooks/
    <scenario>/
      README.md
      input.json
      expected.json
data/
  data-sample.json
  data-sample-1.json
scripts/
  invoke-mask.sh
  invoke-mask.ps1
  invoke-restore.sh
  invoke-restore.ps1
  demo-hooks/
    README.md
    01-session-start.sh
    02-user-prompt-submit.sh
    03-pre-tool-use-mask-input.sh
    04-pre-tool-use-read-file.sh
    05-pre-tool-use-external-tool.sh
    06-post-tool-use.sh
    07-pre-compact.sh
    08-subagent-start.sh
  verify-hook-demo.sh
  run-hook-demo.sh
  run-hook-demo.ps1
tests/
  test-masking.sh
  test-masking.ps1
  fixtures/
    test-email-addresses.json
    test-email-edge-cases.json
```

## Fast Demo

### PowerShell

```powershell
.\scripts\run-hook-demo.ps1 -InputPath .\demo\hooks\01-session-start
.\scripts\run-hook-demo.ps1 -InputPath .\demo\hooks\02-user-prompt-submit
.\scripts\run-hook-demo.ps1 -InputPath .\demo\hooks\03-pre-tool-use-mask-input
.\scripts\run-hook-demo.ps1 -InputPath .\demo\hooks\04-pre-tool-use-read-file
.\scripts\run-hook-demo.ps1 -InputPath .\demo\hooks\05-pre-tool-use-external-tool
.\scripts\run-hook-demo.ps1 -InputPath .\demo\hooks\06-post-tool-use
.\scripts\run-hook-demo.ps1 -InputPath .\demo\hooks\07-pre-compact
.\scripts\run-hook-demo.ps1 -InputPath .\demo\hooks\08-subagent-start
```

### Bash

```bash
bash scripts/run-hook-demo.sh demo/hooks/01-session-start
bash scripts/run-hook-demo.sh demo/hooks/02-user-prompt-submit
bash scripts/run-hook-demo.sh demo/hooks/03-pre-tool-use-mask-input
bash scripts/run-hook-demo.sh demo/hooks/04-pre-tool-use-read-file
bash scripts/run-hook-demo.sh demo/hooks/05-pre-tool-use-external-tool
bash scripts/run-hook-demo.sh demo/hooks/06-post-tool-use
bash scripts/run-hook-demo.sh demo/hooks/07-pre-compact
bash scripts/run-hook-demo.sh demo/hooks/08-subagent-start
```

### Bash Per-State Scripts

```bash
bash scripts/demo-hooks/01-session-start.sh
bash scripts/demo-hooks/02-user-prompt-submit.sh
bash scripts/demo-hooks/03-pre-tool-use-mask-input.sh
bash scripts/demo-hooks/04-pre-tool-use-read-file.sh
bash scripts/demo-hooks/05-pre-tool-use-external-tool.sh
bash scripts/demo-hooks/06-post-tool-use.sh
bash scripts/demo-hooks/07-pre-compact.sh
bash scripts/demo-hooks/08-subagent-start.sh
```

See `scripts/demo-hooks/README.md` for the step-by-step presenter view of these wrapper scripts.

If a sample matches its expected output, the runner prints `Expected output matched.`

See `.github/hooks/scripts/README.md` for an explanation of what each real `.sh` and `.ps1` hook file does and what output it returns.

## Demo Log Files

Each hook state writes a sanitized payload log into `logs/`:

- `logs/demo-01-session-start.json`
- `logs/demo-02-user-prompt-submit.json`
- `logs/demo-03-pre-tool-use.json`
- `logs/demo-04-post-tool-use.json`
- `logs/demo-05-pre-compact.json`
- `logs/demo-06-subagent-start.json`

These files are the center of the simplified demo. After each step runs, open the matching log file and explain the payload for that hook state.

## Demo Files By Hook

| Step | Purpose |
|---|---|
| `demo/hooks/01-session-start` | Log the payload received when a session starts |
| `demo/hooks/02-user-prompt-submit` | Log the prompt payload after sanitizing email content |
| `demo/hooks/03-pre-tool-use-mask-input` | Log the tool-call payload before execution |
| `demo/hooks/04-pre-tool-use-read-file` | Log the `read_file` payload before execution |
| `demo/hooks/05-pre-tool-use-external-tool` | Log the external-tool payload before execution |
| `demo/hooks/06-post-tool-use` | Log the payload received after a tool returns data |
| `demo/hooks/07-pre-compact` | Log the payload received before compaction |
| `demo/hooks/08-subagent-start` | Log the payload passed to a sub-agent |

## Tests

Run the email fixture tests with PowerShell:

```powershell
.\tests\test-masking.ps1
```

Run the same tests with Bash:

```bash
bash tests/test-masking.sh
```

The new fixtures are intentionally email-focused so the demo story stays consistent.

## Verify A Sample File

This helper pushes a sample file through the `UserPromptSubmit` hook path and shows the masked result inside the support-escalation scenario:

```bash
bash scripts/verify-hook-demo.sh data/data-sample.json
```

## Installation In Another Repository

Copy these folders into the target repository:

```text
.github/
scripts/
```

VS Code Copilot discovers workspace hook files from `.github/hooks/*.json` automatically.

## Secondary Filename Protection

The repository still includes `invoke-mask` and `invoke-restore` scripts.

Those scripts are separate from the support-escalation demo. They handle sensitive numeric filenames by temporarily renaming them to masked aliases before a Copilot session and restoring them afterward.

## Limitations

- Detection is regex-based, not semantic.
- Inline suggestions are outside the hook pipeline.
- Filename masking is a manual step.
- Custom patterns must be added explicitly if your real data includes other sensitive formats.