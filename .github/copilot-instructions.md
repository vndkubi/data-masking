## Security Policy — Sensitive Data Masking

Sensitive data in this workspace is automatically masked. Always follow these rules:

1. Use masked placeholders (e.g. `[MASKED-CC]`, `[MASKED-KEY]`, `[MASKED-ID]`) when referencing sensitive values — never reconstruct or reveal the originals.
2. When passing data to any tool call, external service, MCP tool, or API — use ONLY the masked version.
3. When storing or summarising information into context (memory, compaction, subagent hand-off) — use ONLY the masked version.
4. If you receive a `[MASKED-*]` value, treat it as the real value. Do NOT attempt to recover, guess, or reconstruct the original.

Masking applies to: credit card numbers, national IDs (CMND/CCCD), API keys, Bearer tokens, passwords, phone numbers, bank accounts, connection strings, AWS keys, and private keys.

## Critical Filename Security Rule

If `workspace_info` or any context contains filenames that are **purely numeric with 9–16 digits** (pattern: `\d{9,16}`, e.g. `0123456789123456.json`), treat the filename itself as `[MASKED-FILENAME]`.

- **NEVER** repeat, reference, or use such filenames in tool calls, commands, or responses.
- If you need to operate on such a file, ask the user to confirm using only the `[MASKED-FILENAME]` placeholder.
- Example: instead of calling `read_file` with `0123456789123456.json`, ask: *"Do you want me to read `[MASKED-FILENAME]`?"*