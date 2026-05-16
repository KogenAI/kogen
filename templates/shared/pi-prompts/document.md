---
description: Document session decisions, issues, root causes, and proposed changes into a living design spec
---

Write markdown document capturing everything discussed — issues found, root causes, proposed changes, decisions made.

**PURPOSE**: Durable, actionable design document from a design/architecture discussion. Comprehensive enough that someone can understand what was decided and why, and can implement without re-reading the conversation.

**CRITICAL RULES:**

- **No unanswered questions** — if genuinely unclear, ask before writing. Don't paper over ambiguity.
- **Do NOT re-ask what user already answered.** If user said "I don't care about X", don't ask "should I also cut Y?" — generalize the filter and apply it. Ask only when two reasonable interpretations lead to materially different documents. Apply the broader interpretation (cut more, not less).
- **Trust scope signals.** "Stuff like this", "for now", "focus on bigger things" → infer the class they're de-prioritizing and filter accordingly.
- **No "optional" or "low priority" labels** — everything in the document is work that needs to happen. If unsure whether to include, ask. Items marked optional get ignored.
- **No speculative future work** — only actionable changes now.
- **Root causes, not just symptoms** — every issue must explain _why_ it happens.
- **Decisions must include rationale** — "we decided X" is incomplete. "We decided X because Y" is useful.

**PROCESS:**

1. **Re-read entire conversation** exhaustively. Extract:
   - Issues/bugs (with root causes)
   - Design decisions (with rationale)
   - Proposed changes (grouped logically)
   - Anything user explicitly included or excluded
   - Back-and-forth resolutions — capture resolution, not the debate

2. **Check gaps and second-order consequences** before writing:
   - Issues mentioned but never resolved?
   - Proposed changes without clear scope?
   - Decisions that contradict each other?
   - For every decision: what breaks? What assumptions does this invalidate?
   - For every "skip this": is there a straightforward solution? Never recommend skipping without exhausting alternatives.
   - For every external dependency: verify capabilities BEFORE writing the plan. SSH to server, check API docs, test against sandboxes. A plan built on unverified assumptions wastes all time spent discussing and splitting.
   - **Verify easily-checkable claims immediately, not via TODOs.** If claim can be verified with one command, run it. Never write "verify X works before rollout" when you could run X in 10 seconds.

3. **Write document:**
   - Overview / context (brief)
   - Issues and root causes
   - Proposed changes (grouped by area, not chronologically)
   - Implementation plan (phased if complex, flat if simple) — each phase is one commit. The rationale you record per § Proposed Changes entry becomes `/split`'s `Why` field, which the orchestrator copies verbatim into every subagent delegation prompt (planner, developer, reviewer, committer). Write each rationale as the answer to "what concrete failure does this prevent, in language a subagent can act on" — not as design-doc commentary. The committer's commit message will draw from this text; the future debugger reading `git log` will see it. Hedged or vague rationale ("for clarity", "to be consistent") cripples every downstream role.
   - Test coverage gaps
   - Consolidation table (if things were merged/renamed/removed)

4. **Save automatically** — save with a descriptive kebab-case filename. Never ask for path. `mkdir -p codegen/designs/drafts` then save to `codegen/designs/drafts/<slug>.md`, regardless of launcher or `PI_ROLE`. Re-running on an existing slug → Edit in place; the doc is a living spec. Promotion to `codegen/designs/ready/` happens via `/split` when the design is implementation-ready; archival from `ready/` to `codegen/designs/archive/` is manual (ask `pi-build` when work is shipped).

5. **Present summary** so user can verify nothing was missed.

**DOCUMENT QUALITY CHECKS:**

- [ ] Every issue has root cause explanation
- [ ] Every proposed change assigned to phase/section
- [ ] No items marked "optional", "low priority", "nice to have"
- [ ] No speculative future work without concrete plan
- [ ] All decisions include rationale
- [ ] No unanswered questions
- [ ] Implementation plan covers all proposed changes

**DO NOT:**

- Make code changes
- Add items user didn't discuss or agree to
- Use priority labels to defer work — if not worth doing, cut it; if it is, include without caveats
- Write chronologically — organize by topic/area
