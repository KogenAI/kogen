---
description: Research a technical topic before acting — investigate how things actually work, then report findings
argument-hint: [topic or question]
---

Research the given topic thoroughly before drawing any conclusions. The goal is to understand how something actually works — not to jump to a solution.

1. **Identify what needs to be understood** — what is the actual question? What assumptions might be wrong? What could the root cause be?

2. **Search the web in parallel** — run 6-10 searches simultaneously covering:
   - Official docs for any tools/libraries involved
   - How the underlying system/mechanism works (e.g. "how does bash load PATH in non-interactive mode")
   - Known gotchas, edge cases, common mistakes
   - GitHub issues, Stack Overflow, official changelogs

3. **Read the relevant source** — if the answer is in a config file, source code, or system file on the server, read it directly. Don't guess.

4. **Report findings as facts** — present what you learned:
   - What actually happens (the mechanism)
   - What the root cause is, if diagnosing a problem
   - What the options are, with concrete trade-offs
   - A clear recommendation with reasoning

**Don't**: propose solutions before understanding the problem. Don't assume. Don't hallucinate library APIs — look them up.
