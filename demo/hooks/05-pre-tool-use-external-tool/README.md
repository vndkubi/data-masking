# 05 PreToolUse External Tool

Hook event: `PreToolUse`

Use this scenario to show the confirmation step before a support lookup sends customer data to an external service.

What to point out in the demo:

- The query contains a raw email address.
- The hook does not auto-send the data.
- The hook returns `permissionDecision = ask`.

Files in this folder:

- `input.json`: external-tool payload with sensitive content
- `expected.json`: expected confirmation output