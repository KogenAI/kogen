---
description: Check if current pitch is ready for development and move it to ready/
---

Read the pitch currently in scope. Understand it — problem, solution, constraints, tradeoffs stated, risks.

Ask yourself: Is this pitch ready for a developer to build without asking you clarifying questions?

**Ready** = Problem clear, solution decided, scope bounded, assumptions stated, no open questions in the prose.

**Not ready** = Open questions remain (even in casual phrasing), multiple options without a choice, vague requirements, unresolved tradeoffs, inconsistencies between sections.

**If ready**: Move `codegen/pitches/draft/<slug>.md` → `codegen/pitches/ready/<slug>.md`. Bash: `mv <source> <dest>`. Report: "READY. Moved to ready/."

**If not ready**: List what's unresolved and where (cite line or section). Be specific — quote the question or inconsistency. Stop. Do not move file.

**FORBIDDEN**: Suggest edits. Ask user. Just assess readiness.
