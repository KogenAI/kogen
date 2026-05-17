---
description: Capture current session discussion into a short pitch skeleton for later shaping
---

Write a short pitch skeleton capturing the essence of what was discussed — a seed for later shaping, not a full design doc.

**PURPOSE**: Quick capture. Durable skeleton drops into `codegen/pitches/draft/` so it can be opened in a shaping session (`pi-shape` / `claude-shape`) later. Not a plan. Not a spec. Just enough to remember the problem and the open questions.

**SKELETON SHAPE** (all sections, keep each to 2–5 lines):

1. **Problem** — Extract from conversation. Quote the user's wording where it matters. 2–4 sentences max.
2. **Open questions** — Unresolved items from the conversation. These become the first AskUserQuestion batch in the shaping session.
3. **Context consulted** — Paths touched in this session. Paths only.

**FORBIDDEN sections**: Appetite, Solution sketch, Rabbit holes, Implementation plan, Step N, Files Modified, Consolidation, Proposed changes.

**PROCESS:**

1. Re-read the conversation. Extract: the problem statement (user's wording), any unresolved questions, and any paths/files referenced.
2. Write the skeleton — 3 sections only, ≤1 A4 page (~60 lines / ~400 words).
3. Save automatically — kebab-case slug. `mkdir -p codegen/pitches/draft` then save to `codegen/pitches/draft/<slug>.md`. Re-running on existing slug → Edit in place.
4. Present the file path in chat.

**DO NOT:**

- Add Appetite — not decided yet.
- Add Solution sketch — not shaped yet.
- Add Implementation plan or Step N sections.
- Make code changes.
- Ask for the path — generate the slug from the problem statement.
