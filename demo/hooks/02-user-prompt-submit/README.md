# 02 UserPromptSubmit

Hook event: `UserPromptSubmit`

Use this scenario to show how customer contact data is masked before the support request reaches the model.

What to point out in the demo:

- The input contains a raw email address.
- The output rewrites it to `[MASKED-EMAIL]`.
- The hook returns `updatedInput.prompt` with sanitized text.

Files in this folder:

- `input.json`: prompt with raw email
- `expected.json`: expected masked prompt output