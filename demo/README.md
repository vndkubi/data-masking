# Hook Demo Samples

This demo is organized as a simple hook-state walkthrough.

Story line:

- Start one hook state.
- Let the hook write a sanitized payload log.
- Open the generated log file.
- Explain what data Copilot sent into that state.

This directory is organized so each demoable hook scenario has its own folder.

Each folder contains:

- `README.md`: what the scenario demonstrates
- `input.json`: synthetic hook payload
- `expected.json`: expected hook output

Recommended order:

1. `hooks/01-session-start`
2. `hooks/02-user-prompt-submit`
3. `hooks/03-pre-tool-use-mask-input`
4. `hooks/04-pre-tool-use-read-file`
5. `hooks/05-pre-tool-use-external-tool`
6. `hooks/06-post-tool-use`
7. `hooks/07-pre-compact`
8. `hooks/08-subagent-start`

Generated log files to open during the demo:

- `logs/demo-01-session-start.json`
- `logs/demo-02-user-prompt-submit.json`
- `logs/demo-03-pre-tool-use.json`
- `logs/demo-04-post-tool-use.json`
- `logs/demo-05-pre-compact.json`
- `logs/demo-06-subagent-start.json`

Run a scenario on PowerShell:

```powershell
.\scripts\run-hook-demo.ps1 -InputPath .\demo\hooks\02-user-prompt-submit
```

Run a scenario on Bash:

```bash
bash scripts/run-hook-demo.sh demo/hooks/02-user-prompt-submit
```

The runners still accept explicit input and expected file paths when needed.

Run a state directly with its dedicated shell script:

```bash
bash scripts/demo-hooks/02-user-prompt-submit.sh
```

For the wrapper-script walkthrough, see `scripts/demo-hooks/README.md`.