# Demo Hook Wrapper Scripts

This folder contains one Bash wrapper script per demo step.

Each script calls `scripts/run-hook-demo.sh` with the matching scenario under `demo/hooks/`, so you can present the full support-escalation story one step at a time without typing long commands.

## What These Scripts Are For

- Quick live demo from one folder
- Step-by-step walkthrough of each hook event
- Easier presentation flow for Bash or WSL users

## Demo Order

1. `01-session-start.sh`
   Shows the support-escalation policy injected at session start.
2. `02-user-prompt-submit.sh`
   Shows prompt masking for customer email data.
3. `03-pre-tool-use-mask-input.sh`
   Shows automatic masking of internal tool input.
4. `04-pre-tool-use-read-file.sh`
   Shows deny-and-sanitize behavior for sensitive file reads.
5. `05-pre-tool-use-external-tool.sh`
   Shows the confirmation step before sending sensitive data to an external tool.
6. `06-post-tool-use.sh`
   Shows masking of sensitive data returned by a tool.
7. `07-pre-compact.sh`
   Shows the reminder before compacting context.
8. `08-subagent-start.sh`
   Shows the inherited masking policy for sub-agents.

## Usage

Run any step directly:

```bash
bash scripts/demo-hooks/01-session-start.sh
```

Run the full sequence manually in order:

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

If the scenario output matches the expected file, the runner prints `Expected output matched.`

## Notes

- These wrappers are Bash entrypoints only.
- They depend on `scripts/run-hook-demo.sh`.
- The actual payloads and expected outputs live under `demo/hooks/`.