---
description: Audit a design document against the actual implementation — report what's implemented, tested, missing, or partial
argument-hint: [path to design doc]
---

Compare design document against codebase. Locate document in priority order:

1. **Argument** — use path provided directly
2. **Conversation history** — scan recent messages for referenced document
3. **`codegen/` directory** — glob `codegen/*.md`, pick most recently modified doc that looks like a design/spec (not session log)

## Process

1. **Read design doc** in full — extract every proposed change, feature, and test coverage item.

2. **Check codebase** — for each item, grep and read relevant source/test files to verify:
   - ✅ Implemented — code exists and matches spec
   - ✅ Tested — test exists covering behavior
   - ⚠️ Partial — exists but incomplete or diverges
   - ❌ Missing — not implemented at all

3. **Produce table** grouped by phase/section:

   | Item | Implemented | Tested   | Notes |
   | ---- | ----------- | -------- | ----- |
   | ...  | ✅/⚠️/❌    | ✅/⚠️/❌ | ...   |

4. **List gaps** — anything ❌ Missing or ⚠️ Partial with brief explanation.

5. **Do not fix anything** — report only.

## Rules

- Check impl AND tests separately — code can exist without tests and vice versa
- Read actual source files, don't infer from file names
- If spec item is ambiguous, note it rather than guessing
- Keep report concise — one line per item in table, gaps section only for items needing attention
