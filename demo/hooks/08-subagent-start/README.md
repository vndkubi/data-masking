# 08 SubagentStart

Hook event: `SubagentStart`

Use this scenario to show how the support-escalation policy is inherited by sub-agents.

What to point out in the demo:

- The hook injects inherited masking context.
- The output reminds the sub-agent to use `[MASKED-EMAIL]` only.

Files in this folder:

- `input.json`: synthetic sub-agent payload
- `expected.json`: expected inherited-policy output