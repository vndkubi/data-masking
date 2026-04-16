# Demo Scenarios

This folder contains deterministic sample payloads for the `PreToolUse` email policy hook.

Each scenario directory contains:

- `input.json`: the payload sent to the hook
- `expected.json`: the exact hook response expected from the runner

Scenarios:

- `01-allow-email`: valid email, unchanged arguments
- `02-block-email`: blocked domain, denied action with a message
- `03-normalize-email`: email is trimmed and lowercased before execution

## Recommended Input Per Scenario

Base payload shape:

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

Use these `email` values for each case:

- `01-allow-email`: `dana@contoso.com`
- `02-block-email`: `partner@blocked.example`
- `03-normalize-email`: `  Alice.Nguyen@Example.com  `

Expected behavior:

- `01-allow-email`: returns `allow`; the email stays as-is.
- `02-block-email`: returns `deny`; the response message says the domain is not allowed.
- `03-normalize-email`: returns `allow` with `updatedInput`; the email becomes `alice.nguyen@example.com`.