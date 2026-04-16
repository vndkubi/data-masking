# 01 SessionStart

Hook event: `SessionStart`

Use this scenario to open the support-escalation story and show what policy the agent receives at session start.

What to point out in the demo:

- The hook injects the support-escalation masking policy into context.
- The output contains `hookEventName = SessionStart`.
- The `additionalContext` text explains the active masking rules.

Files in this folder:

- `input.json`: synthetic hook payload
- `expected.json`: expected sanitized hook output