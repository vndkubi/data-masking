# Copilot CLI Bundle

This bundle is the stripped-down path for `~/.copilot` usage.

## Why this version is simpler

- One runtime only: `pwsh` (PowerShell 7+) on Windows and macOS.
- One masking engine only: `cli/hooks/scripts/mask-sensitive-data.ps1`.
- One hook wiring file only: `cli/hooks/sensitive-data-mask.json`.
- No `bash` masking logic, no `jq`, no `perl`, no duplicated regex handling.
- No embedded fallback patterns inside the script. All masking rules live in `masking-config.json`.
- If config cannot be found or parsed, the hook skips quietly and writes the reason to `~/.copilot/logs/mask-sensitive-data.log`.

## Supported platforms

- Windows with PowerShell 7+
- macOS Intel with PowerShell 7+
- macOS Apple Silicon with PowerShell 7+

## Install

Run the installer from the repo root:

```powershell
# Windows PowerShell / PowerShell 7
.\cli\install.ps1

# macOS
pwsh ./cli/install.ps1
```

Default target is `~/.copilot`.

Use a custom target when you want to test the bundle without touching your real Copilot setup:

```powershell
.\cli\install.ps1 -CopilotHome "$HOME/.copilot-test"
```

The installer copies these files into your global Copilot directory:

```text
~/.copilot/
  masking-config.json
  hooks/
    sensitive-data-mask.json
    scripts/
      mask-sensitive-data.ps1
```

## Customization

Edit `~/.copilot/masking-config.json` to add or disable regex rules.

`masking-config.json` is required. The script does not ship with a backup default ruleset anymore.

Config lookup order is:

1. `MASK_DATA_CONFIG`
2. `<workspace>/.copilot/masking-config.json`
3. `<workspace>/.github/hooks/masking-config.json`
4. `~/.copilot/masking-config.json`

The first existing file wins. If that file is invalid or unreadable, the hook logs the error and exits without rewriting anything.

## Script structure

The PowerShell file is intentionally thin and split into three parts:

- Input and config loading
- Small masking helpers
- One `switch` for hook-event behavior

Comments in the script are there to explain those three phases, not to narrate every line.

## Hook behavior kept in this bundle

- `SessionStart`: injects the masking policy reminder.
- `PreToolUse`: asks, denies, redirects, or rewrites tool args when sensitive data is found.
- `PreCompact`: injects a compact reminder.
- `SubagentStart`: re-injects the masking policy for spawned agents.

## Hook behavior intentionally removed

- `UserPromptSubmit`: removed to avoid pretending the prompt is rewritten when the CLI hook contract is inconsistent across environments.
- `PostToolUse`: removed because the previous implementation only logged after the fact and did not materially protect output.

## Runtime requirement

The `bash` hook entry now shells directly into `pwsh`, so install PowerShell once and the same script works on both Windows and macOS.