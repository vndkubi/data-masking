# mask-data

A starter kit for masking sensitive data in GitHub Copilot hooks with custom regex patterns. The hook rewrites tool arguments, blocks risky file paths, and can redirect file reads to masked temporary copies before Copilot sees the content.

## Runtime model

- Repo-local bundle: `.github/hooks/*`
- Global CLI bundle: `cli/*` installed into `~/.copilot`
- Windows native: Windows PowerShell 5.1
- macOS, Linux, WSL, devcontainer: PowerShell 7 via `pwsh`
- No `jq`, `perl`, Python, or Git Bash is required by the masking engine

Important for `devcontainer + WSL`:

- If Copilot is running inside the dev container, the hook runs inside the container too.
- Installing `pwsh` on Windows or on the outer WSL distro is not enough for that case.
- The container image itself must provide `pwsh`.

## Project structure

```text
.github/
  copilot-instructions.md
  hooks/
    masking-config.json
    sensitive-data-mask.json
    scripts/
      mask-sensitive-data.ps1
      mask-command-output.ps1
cli/
  install.ps1
  validate-config.ps1
  preview-mask.ps1
  masking-config.json
  lib/
    mask-data-tools.ps1
  hooks/
    sensitive-data-mask.json
    scripts/
      mask-sensitive-data.ps1
data/
  data-sample.json
tests/
  fixtures/
    test-sample-patterns.json
  test-masking.ps1
  test-masking.sh
scripts/
  invoke-mask.ps1
  invoke-mask.sh
  invoke-restore.ps1
  invoke-restore.sh
  verify-mask-sensitive-data.sh
```

`scripts/` contains older filename-renaming helpers. They are optional and not part of the main hook-based path.

## Quick start

### 1. Repo-local hooks

The `.github/hooks` folder is self-contained. If you want masking to travel with the repository, this is the main bundle.

```text
your-project/
  .github/
    copilot-instructions.md
    hooks/
      masking-config.json
      sensitive-data-mask.json
      scripts/
        mask-sensitive-data.ps1
        mask-command-output.ps1
```

Copy `cli/` as well if you want the local helper commands: `validate-config`, `preview-mask`, and the global installer.

### 2. Global CLI install

Install the same hook for all repositories on the current machine:

```powershell
# Windows PowerShell 5.1
powershell -NoProfile -ExecutionPolicy Bypass -File .\cli\install.ps1

# macOS / Linux / WSL
pwsh ./cli/install.ps1
```

The installer writes:

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

Useful flags:

```powershell
.\cli\install.ps1 -Check
.\cli\install.ps1 -NoBackup
.\cli\install.ps1 -CopilotHome "$HOME/.copilot-test"
```

## Devcontainer and WSL

For `WSL` without devcontainer, install `pwsh` in the Linux environment that actually runs Copilot CLI.

For `devcontainer` inside WSL2:

1. Add PowerShell 7 to the container image.
2. Rebuild the container.
3. Verify inside the container with `pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion'`.

The repo-local hook file already targets the Linux shell path through the `bash` command and the Windows path through the `powershell` command. No extra Bash masking script is needed.

## Config

Configs are strict JSON. Do not comment out rules. Disable them with `"enabled": false`.

The starter config intentionally stays small:

- `Credit Card`
- `API Key`
- `Bearer Token`
- `Password Assignment`
- `Demo Customer ID` in `customPatterns`

Example:

```json
{
  "name": "Order ID",
  "enabled": true,
  "regex": "(?i)(\"?order_id\"?\\s*[:=]\\s*\"?)ORD-\\d{8}",
  "replacement": "$1[MASKED-ORDER-ID]"
}
```

Runtime config lookup order:

1. `MASK_DATA_CONFIG`
2. `<workspace>/.copilot/masking-config.json`
3. `<workspace>/.github/hooks/masking-config.json`
4. `~/.copilot/masking-config.json`

The first existing file wins.

## Local tools

Validate config shape, regex syntax, and duplicate replacements:

```powershell
.\cli\validate-config.ps1
.\cli\validate-config.ps1 -Strict
```

Preview masking for a string:

```powershell
.\cli\preview-mask.ps1 -Text 'customer_id=CUST-123456 password=DemoPass123'
```

Preview masking for a file:

```powershell
.\cli\preview-mask.ps1 -FilePath .\data\data-sample.json
```

## Test

Windows PowerShell 5.1 or `pwsh`:

```powershell
.\tests\test-masking.ps1
```

Linux, macOS, WSL, or devcontainer:

```bash
bash tests/test-masking.sh
```

The shell wrapper now runs the same PowerShell fixture test through `pwsh`, so it reflects the real runtime path on Unix-like environments.

## Hook behavior

- `SessionStart`: injects the masking policy into session context
- `PreToolUse`: masks tool args, blocks sensitive numeric file paths, and asks before sending masked content to external tools
- `PreCompact`: reminds Copilot to keep only masked placeholders
- `SubagentStart`: passes the masking policy to spawned agents

## Limits

- Detection is regex-only. If the pattern misses, the hook misses.
- Inline suggestions are not covered. This project only helps Copilot chat / hook flows.
- Linux-side environments must provide `pwsh`.
- IntelliJ and other JetBrains IDEs do not expose the same hook API.
