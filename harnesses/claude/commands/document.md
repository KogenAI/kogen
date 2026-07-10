---
description: Capture current session discussion into a short pitch skeleton for later shaping
---

Write a short pitch skeleton capturing the essence of what was discussed — a seed for later shaping, not a full design doc.

**PURPOSE**: Quick capture from any session (orchestrator, `claude-build`, `claude-shape`, `claude-debug`). Drops a skeleton into `codegen/pitches/draft/` for later shaping. Not a plan. Not a spec.

**SKELETON SHAPE** (all sections, keep each to 2–5 lines):

1. **Problem** — Extract from conversation. Quote the user's wording where it matters. 2–4 sentences max. State the **invariant or guarantee being violated**, not the mechanism that enforces it — mechanisms belong in shaping's solution space. Naming a skeleton after the mechanism (`...-must-fail-closed`) is a smell, the same class as naming after the symptom (`...-blank-cockpit`); prefer an invariant-named slug (`no-ship-on-unconfirmed-gate`).
2. **Open questions** — Unresolved items from the conversation. These become the first things the shaping session investigates and resolves — asking only if no sensible default exists.
3. **Context consulted** — Paths touched in this session. Paths only.

**Status enum**: Begin the file with a YAML frontmatter block whose `status:` field is `SKELETON` (e.g. `---\nstatus: SKELETON\n---\n`). The enum has three values — SKELETON (raw, this command), SHAPING (shape session mid-investigation), SHAPED (fully designed, no open questions). SHAPING/SHAPED are set by the shape session; this command always writes SKELETON.

**FORBIDDEN sections**: Appetite, Solution sketch, Rabbit holes, Implementation plan, Step N, Files Modified, Consolidation, Proposed changes, Why one commit.

**ONE SKELETON = ONE PROBLEM**: one invariant per skeleton. Defense-in-depth — the same guarantee enforced by two mechanisms (e.g. a gate failing closed AND downstream roles refusing) — belongs in ONE skeleton's open questions, not in N sibling skeletons. Two mechanisms for one invariant is still one problem.

**PROCESS:**

1. Re-read the conversation. Extract: the problem statement (user's wording), any unresolved questions, and any paths/files referenced.
2. Write the `status: SKELETON` frontmatter block as the first lines of the file, then write the skeleton — 3 sections only, ≤1 A4 page (~60 lines / ~400 words).
3. **Dedup scan before write.** Before creating a new skeleton, scan `codegen/pitches/draft/` and `codegen/pitches/ready/` for an existing skeleton covering the same invariant or incident. Signal for "same invariant": shared incident + shared evidence (same session log or same commit) + the candidate references, or is referenced by, an existing draft. **Merge** when the candidate is a different MECHANISM for an invariant an existing draft already states → EDIT that existing skeleton in place, adding the new mechanism as an open question, and present its path with a one-line note `merged into existing skeleton <slug> (same invariant, additional mechanism)`. **Split** (write a new sibling) only when the candidate is a different FAILURE that occurs even when the other is fixed (genuinely independent problem). Do not prompt the operator at write time — bias toward one skeleton; the shape session resolves any genuine ambiguity later.
4. Save automatically — kebab-case slug. Resolve the DURABLE main-repo root first: `ROOT="${CODEGEN_PITCH_ROOT:-$(cd "$(dirname "$(git rev-parse --git-common-dir 2>/dev/null)")" 2>/dev/null && pwd || pwd)}"` — this is `$CODEGEN_PITCH_ROOT` in an experiment session (the ephemeral `--worktree` cwd would otherwise lose the file at `--done`), else cwd (the main root) in a normal session. Then `mkdir -p "$ROOT/codegen/pitches/draft"` and save to `$ROOT/codegen/pitches/draft/<slug>.md`. Re-running on existing slug → Edit in place; the doc is a living skeleton. Same problem under a different slug (per the dedup scan above) → Edit the existing draft, do not create a sibling.
5. Present the file path in chat. Done.

**DO NOT:**

- Add Appetite or Solution sketch — not shaped yet.
- Add Implementation plan or Step N sections.
- Add `/split`-style promotion. Manual `mv codegen/pitches/draft/<slug>.md codegen/pitches/ready/<slug>.md` is the bet.
- Make code changes.
- Ask for the path — generate the slug from the problem statement.
