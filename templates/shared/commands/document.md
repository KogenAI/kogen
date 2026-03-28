---
description: Document session decisions, issues, root causes, and proposed changes into a living design spec
---

Write a markdown document that captures everything discussed in this conversation session — issues found, their root causes, proposed changes, and decisions made.

**PURPOSE**: Create a durable, actionable design document from a design/architecture discussion. The document should be comprehensive enough that someone reading it can understand what was decided and why, and can implement the changes without re-reading the conversation.

**CRITICAL RULES**:

- **No unanswered questions** — if something is unclear, ask the user before writing. Don't paper over ambiguity with vague language.
- **No "optional" or "low priority" labels** — everything in the document is work that needs to happen. If you're unsure whether something should be included, ask. Items marked optional get ignored — either commit to it or cut it.
- **No speculative future work** — only include changes that are actionable now. "Potential future responsibilities" or "nice to have" sections just create noise. If a capability doesn't exist yet and there's no plan to build it, leave it out.
- **Root causes, not just symptoms** — every issue must explain _why_ it happens, not just _what_ happens.
- **Decisions must include rationale** — "we decided X" is incomplete. "We decided X because Y" is useful.

**PROCESS**:

1. **Re-read the entire conversation** exhaustively. Extract:
   - Issues/bugs identified (with root causes)
   - Design decisions made (with rationale)
   - Proposed changes (grouped logically)
   - Anything the user explicitly said to include or exclude
   - Any back-and-forth that resolved an ambiguity — capture the resolution, not the debate

2. **Check for gaps** before writing:
   - Are there any issues mentioned but never resolved?
   - Are there proposed changes without clear scope?
   - Are there decisions that contradict each other?
   - If gaps exist, ask the user to clarify before proceeding.

3. **Write the document** with this structure:
   - Overview / context (brief — what this document is about)
   - Issues and root causes
   - Proposed changes (grouped by area, not chronologically)
   - Implementation plan (phased if complex, flat list if simple)
   - Test coverage gaps to address
   - Consolidation table (if things were merged/renamed/removed)

4. **Save automatically** — always save to `codegen/` with a descriptive kebab-case filename derived from the topic (e.g. `codegen/bouncer-post-deploy-fixes.md`). Never ask the user for a path.

5. **Present a summary** of what's in the document so the user can verify nothing was missed.

**DOCUMENT QUALITY CHECKS**:

Before presenting the document, verify:

- [ ] Every issue has a root cause explanation
- [ ] Every proposed change is assigned to a phase or section (nothing floating)
- [ ] No items marked as "optional", "low priority", "nice to have", or "worth considering"
- [ ] No speculative future work without a concrete plan
- [ ] All decisions include rationale
- [ ] No unanswered questions — if uncertain, asked the user first
- [ ] Implementation plan covers all proposed changes (nothing mentioned in the body but missing from the plan)

**DO NOT**:

- Make code changes
- Create implementation PRs
- Add items the user didn't discuss or agree to
- Use priority labels as a way to defer work — if it's not worth doing, cut it; if it is, include it without caveats
- Write the document chronologically (conversation order) — organize by topic/area
