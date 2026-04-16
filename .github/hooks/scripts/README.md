# Hook Script Implementations

This folder contains the real hook implementations for the simplified hook-state logging demo.

Each step has two entrypoints with the same behavior:

- `.sh` for Bash environments such as Linux, macOS, WSL, or Git Bash
- `.ps1` for PowerShell on Windows

In other words, each pair does the same job and returns the same JSON shape. The only difference is the shell runtime.

## Shared Helper Files

- `hook-demo-common.sh`
  Shared Bash helper layer for config loading, masking, sensitive-data detection, path resolution, audit logging, and per-state payload log generation.
- `HookDemoCommon.ps1`
  Shared PowerShell helper layer for the same support functions on Windows.

## Step By Step

### 01 SessionStart

Files:

- `01-session-start.sh`
- `01-session-start.ps1`

What they do:

- Capture the incoming `SessionStart` payload.
- Sanitize sensitive values if needed.
- Write the sanitized payload to `logs/demo-01-session-start.json`.

Output:

- Returns `hookSpecificOutput.hookEventName = SessionStart`
- Returns `hookSpecificOutput.additionalContext`
- The output tells you which log file to open for the demo.

### 02 UserPromptSubmit

Files:

- `02-user-prompt-submit.sh`
- `02-user-prompt-submit.ps1`

What they do:

- Capture the incoming `UserPromptSubmit` payload.
- Sanitize the prompt so raw email becomes `[MASKED-EMAIL]`.
- Write the sanitized payload to `logs/demo-02-user-prompt-submit.json`.

Output:

- Returns `hookSpecificOutput.hookEventName = UserPromptSubmit`
- Returns `permissionDecision = allow`
- Returns `updatedInput.prompt` with the masked prompt text
- Returns `systemMessage` pointing you to the generated log file

### 03 PreToolUse

Files:

- `03-pre-tool-use.sh`
- `03-pre-tool-use.ps1`

What they do:

- Run before a tool is executed.
- Capture the incoming `PreToolUse` payload.
- Sanitize tool input if it contains email data.
- Write the sanitized payload to `logs/demo-03-pre-tool-use.json`.

Output:

- Returns `permissionDecision = allow`
- Returns `updatedInput` with sanitized content when applicable
- Returns `additionalContext` pointing you to the generated log file

### 04 PostToolUse

Files:

- `04-post-tool-use.sh`
- `04-post-tool-use.ps1`

What they do:

- Run after a tool returns data.
- Capture the incoming `PostToolUse` payload.
- Sanitize the tool response preview.
- Write the sanitized payload to `logs/demo-04-post-tool-use.json`.

Output:

- Returns `hookSpecificOutput.hookEventName = PostToolUse`
- Returns `hookSpecificOutput.additionalContext`
- The context points you to the generated log file and shows a short sanitized preview

### 05 PreCompact

Files:

- `05-pre-compact.sh`
- `05-pre-compact.ps1`

What they do:

- Run before context compaction.
- Capture the incoming `PreCompact` payload.
- Write the sanitized payload to `logs/demo-05-pre-compact.json`.

Output:

- Returns `systemMessage`
- The message points you to the generated log file

### 06 SubagentStart

Files:

- `06-subagent-start.sh`
- `06-subagent-start.ps1`

What they do:

- Run before a sub-agent starts.
- Capture the incoming `SubagentStart` payload.
- Write the sanitized payload to `logs/demo-06-subagent-start.json`.

Output:

- Returns `hookSpecificOutput.hookEventName = SubagentStart`
- Returns `hookSpecificOutput.additionalContext`
- The output points you to the generated log file

## Typical Output Shapes

The demo scripts return one of these output patterns:

- `hookSpecificOutput.additionalContext`
  Used for policy or sanitized follow-up context.
- `hookSpecificOutput.updatedInput`
  Used when the hook rewrites tool input or prompt input.
- `hookSpecificOutput.permissionDecision`
  Used when the hook allows, denies, or asks before the next action.
- `systemMessage`
  Used for reminder-style messages such as `PreCompact`.

## Where To See Exact Output

The exact expected output for each step is stored in:

- `demo/hooks/01-session-start/expected.json`
- `demo/hooks/02-user-prompt-submit/expected.json`
- `demo/hooks/03-pre-tool-use-mask-input/expected.json`
- `demo/hooks/04-pre-tool-use-read-file/expected.json`
- `demo/hooks/05-pre-tool-use-external-tool/expected.json`
- `demo/hooks/06-post-tool-use/expected.json`
- `demo/hooks/07-pre-compact/expected.json`
- `demo/hooks/08-subagent-start/expected.json`

## Generated Demo Logs

When the demo runs, these files are created under `logs/`:

- `logs/demo-01-session-start.json`
- `logs/demo-02-user-prompt-submit.json`
- `logs/demo-03-pre-tool-use.json`
- `logs/demo-04-post-tool-use.json`
- `logs/demo-05-pre-compact.json`
- `logs/demo-06-subagent-start.json`

These log files are now the main thing to present during the demo.