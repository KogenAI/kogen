---
description: Research a technical topic before acting — investigate how things actually work, then report findings
argument-hint: [topic or question]
---

Research topic thoroughly before drawing conclusions. Goal: understand how something works, not jump to solution.

1. **Identify what needs understanding** — actual question? wrong assumptions? root cause?

2. **Search web in parallel** — run 6-10 searches simultaneously:
   - Official docs for tools/libs involved
   - How underlying mechanism works (e.g. "how does bash load PATH in non-interactive mode")
   - Known gotchas, edge cases, common mistakes
   - GitHub issues, Stack Overflow, official changelogs

3. **Read relevant source** — if answer is in config, source code, or system file, read it directly. Don't guess.

4. **Report findings as facts**:
   - What actually happens (mechanism)
   - Root cause, if diagnosing
   - Options with concrete trade-offs
   - Clear recommendation with reasoning

Don't propose solutions before understanding problem. Don't assume. Don't hallucinate library APIs — look them up.
