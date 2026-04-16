# 03 PreToolUse Mask Input

Hook event: `PreToolUse`

Use this scenario to show how an internal support action is sanitized before a normal tool call executes.

What to point out in the demo:

- The tool input contains a raw email address.
- The hook allows execution.
- The hook replaces the tool argument with `[MASKED-EMAIL]` in `updatedInput`.

Files in this folder:

- `input.json`: tool call with sensitive argument
- `expected.json`: expected masked tool input output