# 04 PreToolUse Read File

Hook event: `PreToolUse`

Use this scenario to show how the support workflow blocks raw ticket reads and returns a safe snapshot instead.

What to point out in the demo:

- The target file contains raw email addresses.
- The hook blocks direct read access.
- The hook returns a sanitized version of the file content in the deny reason.

Files in this folder:

- `input.json`: `read_file` request
- `expected.json`: expected deny response with sanitized content