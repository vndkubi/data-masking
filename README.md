# mask-data

Minimal GitHub Copilot hook demo for email input policy decisions.

This branch rebuilds the repository as a focused `PreToolUse` demo. The hook inspects `tool_input.email` and produces one of three outcomes:

1. Allow the action when the email is already valid.
2. Block the action with a message when the email domain is not allowed.
3. Allow the action after normalizing the email arguments.

## Use Case Mapping

The screenshot uses this conceptual shape:

```json
{ "allowed": true }
{ "allowed": false, "message": "Action blocked!" }
{ "allowed": true, "modifiedArgs": { "email": "alice@example.com" } }
```

GitHub Copilot hook scripts return the equivalent fields in a different schema:

- `allowed: true` maps to `hookSpecificOutput.permissionDecision = "allow"`
- `allowed: false` maps to `hookSpecificOutput.permissionDecision = "deny"`
- `message` maps to `hookSpecificOutput.permissionDecisionReason`
- `modifiedArgs` maps to `hookSpecificOutput.updatedInput`

## Demo Scenarios

| Scenario | Outcome | Why |
| --- | --- | --- |
| `demo/hooks/01-allow-email` | allow | The email is already valid and stays unchanged. |
| `demo/hooks/02-block-email` | deny | The email uses a blocked domain. |
| `demo/hooks/03-normalize-email` | allow + updatedInput | The hook trims whitespace and lowercases the email. |

## What To Input Per Case

Each demo payload keeps the same outer shape and only changes the `tool_input.email` value:

```json
{
	"hook_event_name": "PreToolUse",
	"tool_name": "save_customer_email",
	"tool_input": {
		"customerId": "CUST-1001",
		"email": "your-value-here",
		"source": "demo-form"
	}
}
```

Use these values when you want to demonstrate each outcome:

- `01-allow-email`: input a normal valid email such as `dana@contoso.com`. The hook returns `allow` and keeps the same value.
- `02-block-email`: input an email on a blocked domain such as `partner@blocked.example`. The hook returns `deny` with a message explaining that the domain is not allowed.
- `03-normalize-email`: input a valid email with extra spaces or uppercase letters such as `  Alice.Nguyen@Example.com  `. The hook returns `allow` and rewrites the arguments to `alice.nguyen@example.com`.

If you want to explain the policy live, the decision tree is:

1. Missing email: deny.
2. Invalid email format: deny.
3. Blocked domain: deny.
4. Valid but messy casing or spacing: allow with `updatedInput`.
5. Already clean email: allow unchanged.

## Run The Demo

### PowerShell

```powershell
.\scripts\run-hook-demo.ps1 -InputPath .\demo\hooks\01-allow-email
.\scripts\run-hook-demo.ps1 -InputPath .\demo\hooks\02-block-email
.\scripts\run-hook-demo.ps1 -InputPath .\demo\hooks\03-normalize-email
```

### Bash

```bash
bash scripts/run-hook-demo.sh demo/hooks/01-allow-email
bash scripts/run-hook-demo.sh demo/hooks/02-block-email
bash scripts/run-hook-demo.sh demo/hooks/03-normalize-email
```

If the output matches the checked-in expectation file, the runner prints `Expected output matched.`

## Hook Wiring

The active hook config lives in `.github/hooks/03-pre-tool-use.json`.

The Windows implementation is `.github/hooks/scripts/03-pre-tool-use.ps1`.

The Bash implementation is `.github/hooks/scripts/03-pre-tool-use.sh`.