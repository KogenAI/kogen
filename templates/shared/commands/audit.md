---
description: Audit a design document against the actual implementation — report what's implemented, tested, missing, or partial
argument-hint: [path to design doc]
---

Compare the design document against the current codebase. Locate the document using this priority order:

1. **Argument** — use the path provided directly
2. **Conversation history** — if no argument, scan recent messages for a referenced document or design spec (e.g. a file linked with `@` or mentioned by name)
3. **`codegen/` directory** — if nothing in history, glob `codegen/*.md` and pick the most recently modified doc that looks like a design/spec (not a session log)

## Process

1. **Read the design doc** in full — extract every proposed change, feature, and test coverage item.

2. **Check the codebase** — for each item, grep and read the relevant source files and test files to verify whether it is:
   - ✅ Implemented — code exists and matches the spec
   - ✅ Tested — test exists covering the behavior
   - ⚠️ Partial — exists but incomplete or diverges from spec
   - ❌ Missing — not implemented at all

3. **Produce a table** grouped by phase/section (matching the doc structure):

   | Item | Implemented | Tested   | Notes |
   | ---- | ----------- | -------- | ----- |
   | ...  | ✅/⚠️/❌    | ✅/⚠️/❌ | ...   |

4. **List gaps** — anything ❌ Missing or ⚠️ Partial with a brief explanation of what's wrong.

5. **Do not fix anything** — report only. If the user wants fixes, they'll ask.

## Rules

- Check both implementation AND tests separately — code can exist without tests and vice versa
- Read actual source files, don't infer from file names
- If a spec item is ambiguous, note it rather than guessing
- Keep the report concise — one line per item in the table, gaps section only for items needing attention
