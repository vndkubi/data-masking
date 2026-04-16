# 06 PostToolUse

Hook event: `PostToolUse`

Use this scenario to show how a support lookup result is sanitized before it is reused.

What to point out in the demo:

- The tool response contains a raw email address.
- The hook masks the tool output before it is reused.
- The output contains only the sanitized response.

Files in this folder:

- `input.json`: tool response with raw email
- `expected.json`: expected sanitized post-tool output