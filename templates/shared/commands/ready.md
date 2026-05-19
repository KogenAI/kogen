---
description: Check if current pitch is ready for development and move it to ready/
---

Read the pitch currently in scope. Understand it — problem, solution, constraints, tradeoffs stated, risks.

Ask yourself: Is this pitch ready for a developer to build without asking you clarifying questions?

**Ready** = Problem clear, solution decided, scope bounded, assumptions stated, no open questions in the prose.

**Not ready** = Open questions remain (even in casual phrasing), multiple options without a choice, vague requirements, unresolved tradeoffs, inconsistencies between sections, or empirical claims without adjacent probe transcripts in `## References`.

**Empirical-claim check (run before all other readiness checks):** Scan pitch prose for falsifiable assertions about tool/config/code/CI behavior: "X does Y", "X never Y", "X always Y", "deleting X is safe because Y", "only Z triggers Y". For each match: check if a `$ <command>` + fenced output block appears in the same paragraph or under `## References`. If any claim lacks a probe transcript → not ready. List each offending claim with its line number. Do NOT move the file. Allowed probes to run inline: `grep` / `find` / `ls`, `mix help <task>`, `mix test --cover <one_test_file>`, `MIX_ENV=test mix run -e "IO.inspect(...)"`, `git log -p -- <path>`. FORBIDDEN: accepting claim because source code suggests it — must execute the code path.

**If ready**: Move `codegen/pitches/draft/<slug>.md` → `codegen/pitches/ready/<slug>.md`. Bash: `mv <source> <dest>`. Report: "READY. Moved to ready/."

**If not ready**: List what's unresolved and where (cite line or section). Be specific — quote the question or inconsistency. Stop. Do not move file.

**FORBIDDEN**: Suggest edits. Ask user. Just assess readiness.
