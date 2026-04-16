# Hook Wiring Files

The hook wiring is split into one file per event so each hook can be explained independently during a demo.

Each hook file now points to a dedicated execute script in `.github/hooks/scripts/`, and those scripts share only a small support-escalation helper layer.

Files:

- `01-session-start.json` -> `scripts/01-session-start.sh` and `scripts/01-session-start.ps1`
- `02-user-prompt-submit.json` -> `scripts/02-user-prompt-submit.sh` and `scripts/02-user-prompt-submit.ps1`
- `03-pre-tool-use.json` -> `scripts/03-pre-tool-use.sh` and `scripts/03-pre-tool-use.ps1`
- `04-post-tool-use.json` -> `scripts/04-post-tool-use.sh` and `scripts/04-post-tool-use.ps1`
- `05-pre-compact.json` -> `scripts/05-pre-compact.sh` and `scripts/05-pre-compact.ps1`
- `06-subagent-start.json` -> `scripts/06-subagent-start.sh` and `scripts/06-subagent-start.ps1`

Shared helpers:

- `scripts/hook-demo-common.sh`
- `scripts/HookDemoCommon.ps1`

Implementation details:

- `scripts/README.md` explains what each `.sh` and `.ps1` file does and what output shape it returns.

VS Code Copilot merges all `.json` files under `.github/hooks/`, so splitting the wiring does not change behavior.