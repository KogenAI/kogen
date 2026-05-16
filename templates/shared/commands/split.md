---
description: Split work into shippable steps where each commit keeps the system functional
argument-hint: [description of work to split, or reference to a plan/doc]
---

Analyze work described (or current plan/doc if no argument) and split into discrete, independently shippable steps. Some work is too tightly coupled to split — if so, say why rather than forcing artificial split.

**Default to one commit, then justify each additional split.** User invoking `/split` is strong prior toward N>1, but not proof. Many design docs describe one intent across many files — N commits → half-migrated codebase between commits, N× CI runtime, N× review overhead, revertability almost never used. Before producing any step list, answer "could this be one commit?" honestly. If yes or maybe → one step (or "this is one intent, not splittable" reply that updates doc). Only produce N>1 when each additional step ships strictly more value on its own — e.g. independent bug fix, infrastructure useful before rest lands, external dependency benefiting from isolation. "Each commit is smaller" is not a reason.

Strongest signal work is one commit: every candidate step boundary fails scaffold test or regression test below. When that happens, write plan as single step with `## Why one commit, not N` section. User can override; default is honest.

**Single-step plans are the expected shape, not a degenerate case.** A `/split` output of one step with `## Why one commit, not N` is the right answer for most design docs. The visual shape of a numbered list does not justify producing one. If the candidate split has steps whose `Why` fields name failure modes that the later step structurally eliminates, the earlier step is duplicate work and the plan is one commit. If each step's `Value if we stop here` is honest only because the next step might never ship, but in practice all steps ship in the same week, the value framing is artificial and the plan is one commit. Test before producing N>1: "would a reviewer reading just the diff for the combined change be confused about why it exists?" If no — combined diff is coherent — produce one step.

**When the plan is one step, write a `## Why one commit, not N` section** above the step. Name the candidate boundaries you considered and rejected. Cite the failure mode each candidate boundary would expose. This section is what makes the single-step output legibly the right shape rather than a missing-content shape.

**Split lives in the document, not in chat.**

If argument references existing plan/doc (file path, `@path`, or unambiguous reference), the split IS that document's impl plan. Edit file in place — replace existing steps section with new step list. Don't paste full step list into chat. Reply with short summary: how many steps, what changed from prior version (merges, reorderings, cuts), open questions. User reads steps in doc.

If no source document, ask user where to write the plan before producing steps — typically `codegen/` or `docs/`. Don't default to dumping plan into chat. Only when user explicitly asks for chat-only response ("just tell me", "preview only") should steps appear inline.

When reviewing or updating existing split doc: if you reorder steps you MUST rewrite document to reflect new order. Numbers in document are ground truth.

**Promote drafts when splitting them.** If source document path is under `codegen/designs/drafts/`, after rewriting the steps section, move the file: `mv codegen/designs/drafts/<slug>.md codegen/designs/ready/<slug>.md`. The move IS the promotion signal — `drafts/` = still being shaped, `ready/` = step list exists, implementation can start. Mention the new path in the reply. Archival from `ready/` to `codegen/designs/archive/` is manual and only triggered by user instruction to `claude-build` after work ships — never archive from `/split`.

Each Step's `Why` field is a verbatim copy (or one-paragraph compression) of the corresponding entry in the source design doc's § Proposed Changes. Never paraphrase — paraphrase introduces hedging, drops the named alternative, and degrades the field's value as a delegation payload. If a § Proposed Changes entry can't be matched to any step, that's drift between design and plan: flag in the chat reply summary and decide before promoting — either add the missing step or remove the orphaned § Proposed Changes entry from the design doc. Both are valid; ignoring the mismatch is not. If a step has no source § Proposed Changes entry to draw its Why from, the step is malformed and must be sourced (rewrite the design first) or cut.

Each step must:

- Leave system in better state — not just functional, genuinely more valuable even if no further steps ship
- Coherent unit with clear purpose (not just "schema", but "schema that enables X")
- As small as possible while still meaningful
- One-line "why this is valuable on its own" justification — not "system still works" but "here's what you gain"

**Scaffold test**: before accepting a step, ask "if next step never ships, does a user or dev gain anything?" If no — pure scaffolding that only enables next step — merge forward. Struct with no-op fn, migration with no callers, empty module with no behaviour → half-steps, not shippable. Merge forward.

**Why test**: read the Why aloud as the opening line of a planner prompt. Can planner make decisions from it? Can reviewer scope a CR? Can committer write a why-focused message? If the Why is "for parity" / "for clarity" / "for consistency" → planner has no lever. If the Why overlaps a neighboring step's Why → cut signal. Whys that survive name a concrete failure mode in subagent-actionable language.

**Regression test**: ask "if we stop here, is system worse than before?" Step that ships visible placeholder strings, blocks previously-working path without providing new one, writes `TODO_REPLACE_ME` into user artifacts, or leaves two subsystems in contradictory states → regression, not step. Merge forward with whatever step resolves it. Every step must leave system strictly better than previous commit.

Common regression-half-step shapes:

- **Placeholder in output**: recipe ships `XYZ_PLACEHOLDER_URL` as buy-button target. Without follow-up that scans-and-patches, users see literal placeholder. Merge with consumer that replaces it.
- **Enforcement without guidance**: hook/guard blocks behaviour while prompt/rule still instructs agent to attempt it. Agent hits block, no documented alternative, thrashes. Merge enforcement with rule rewrite that supplies alternative.
- **Callers without impl**: wiring feature flag or new branch calling module whose real behaviour lands next step. Branch is dead or broken in production. Merge.
- **Half-migrated state**: renaming half call sites in commit, rest in next. Codebase compiles but readers see two names. Merge or complete rename in one commit.

Steps are building blocks stacked on each other. Step 1 alone is improvement. Step 1+2 is better. Step 1+2+3 is full feature. Stop at any step and have shipped something worthwhile.

Principles for splitting:

- **Additive before behavioral** — schema changes, new modules, new fns with no callers ship first; logic changes using them ship after
- **Infrastructure before wiring** — add plumbing before turning on tap
- **Isolate external dependencies** — Stripe, email, third-party APIs wired in own step for independent testing
- **Cleanup last, but only when it needs to wait** — applies to feature flags, deprecated DB fields, code that must stay live while replacement proves itself. Does NOT apply to code that becomes provably unreachable when callers are removed — remove dead fns in same step that removes last caller.
- **Prefer fewer, meatier steps** — don't split for splitting; step adding only migration with no callers is noise unless migration itself is risky
- **Group identical mechanical moves** — same operation repeated N times (extract handler A, B, C…) is one step, not N. Value comes from pattern established, not each individual move. Split only when moves have different risk profiles or touch different systems.
- **Group one intent across many files** — if design doc's whole purpose is "do X" and impl is "land twelve hooks + cut twelve prose blocks + Makefile target", all of that is one step. Edits not mechanically identical, but intent is one thing. Splitting → commits named "land half the hooks", can't revert independently in useful way, forces codebase through half-migrated state. Test: if every candidate boundary leaves codebase self-contradictory, work is one intent. Ship as one commit.

Output format — for each step:

```
## Step N — [short name]

**What:** One sentence describing what changes.
**Value if we stop here:** One sentence on what's gained even if next step never ships.
**Commit message:** Imperative, under 50 chars, answers *why* not *what*. Bad: "Extract build intents". Good: "Add contact forms to static sites".
**Why:** One sentence naming the concrete failure mode this step prevents — phrased so planner/dev/reviewer/committer can act on it. Not "for clarity" or "to be consistent" — those give a planner no lever. Orchestrator copies this verbatim into every delegation prompt. Source: the corresponding § Proposed Changes entry in the design doc. If the design doc has no usable Why, the step is a candidate for cutting.

[List of specific files/functions/migrations to change]
```

The orchestrator delegating this step constructs each subagent prompt by including the step's `Why` field verbatim above the role-specific instructions. Planner sees `Why: ...` at the top of its prompt; the planner's dev-prompt copies it through; reviewer-phoenix sees it; committer sees it. This is the mechanism by which the design-doc rationale becomes the operative context for every subagent in the chain. Subagents may cite the Why in their session-log section (`## <role> Section`) when explaining decisions. The committer specifically MUST draft its commit message body from the Why, not infer one from the diff — `codegen/rules/roles/committer.md` § why-focused commit messages is satisfied only when committer's prompt contains the Why and committer uses it.

**Context docs ship with the code commit they describe.** Never produce a "context-docs only" commit. Every prose change in `context/*.md`, rule files, or any other documentation that describes runtime behavior MUST be in the same commit as the code that makes the prose true. If a doc edit can't be matched to a code commit (e.g. it documents existing behavior more accurately), it's a separate plan, not a separate commit in this plan. The orchestrator running a step must see the doc and the code land together — otherwise the doc lies for one commit and future bisects through this range read a system that doesn't exist.

Steps are **sequential units of intent on single branch** — not parallel branches or PRs. Each step implemented and committed before next begins.

**A step is one logical change, not one physical commit.** Most steps map 1:1 to one commit, but a step can require multiple physical commits when external constraints force split — most commonly multi-repo workspace where each repo must commit independently. If work is one intent spanning repo boundaries, it is **one step** with N commits inside it, not N steps. Format as single `## Step N` block with `#### Commit 1 (repo: foo)`, `#### Commit 2 (repo: bar)` sub-headers. Future sessions counting "steps" see the right number — one logical unit.

Test: would reverting just one commit leave coherent, shippable intermediate state? Yes → separate steps. No → one step expressed across N commits. Repo-boundary splits almost always fall into second category: half-applied cross-repo changes are incoherent, revert-the-whole-thing is only useful rollback.

**Don't merge steps just because they touch same code or file.** Two changes editing same lines but representing distinct intents (e.g. "make Stripe calls return `{:error, _}` instead of crashing" and "make Stripe calls safe to retry via idempotency keys") are two steps — even if implementing them sequentially means editing same place twice. Cost of touching same place twice is small; cost of merging unrelated intents is muddied history, harder review, step that can't be reverted independently. "It's a 3-line change to same file" or "while we're in there" are not merge reasons. Merge only when two changes are genuinely same intent expressed in two places (e.g. rename touching definition and all call sites — one intent).

**"Too small for planner cycle" is not a cut reason.** If work is worth shipping, it's a step. One-line prose change closing real parity gap is a step. If not worth shipping, drop entirely. Two failure modes: (a) burying small-but-valuable work in `> Human action required` callout where it becomes vague todo future session skips, (b) dropping with note "can ship later" where "later" never arrives. Fix: if worth doing, give step number; if not, delete line.

**Operational actions are not steps.** Deploys, manual verifications, SSH commands, "trigger rebuild", "watch rollup at 02:30 UTC" — no commit, not numbered steps. Put in `> **Human action required after all steps ship:**` callout at end — numbered, human as explicit actor. Numbered step with no commit wastes step slot and misleads future sessions.

**Step numbers ARE execution order. No implicit ordering.**

Document is source of truth for future sessions with none of your context. If steps should run in different order than numbered, two choices only:

1. Renumber steps so physical order matches execution order. Almost always right answer.
2. If can't renumber (e.g. external references point at specific step numbers): add `> **Execution order:** N → M → ...` callout at top of steps section, AND add `**Why this comes after Step X:**` note in each step whose execution order differs.

NEVER tell user "steps execute in order X but labelled Y" in chat without writing it into document. Future session running this document blind follows numbers, not your conversation. Numbers lie → work ships in wrong order.

If work was already split (in plan doc), review existing split and apply improvements directly to document — merging steps that are too granular, splitting steps that do too much, reordering steps with hidden dependencies. Cut step count significantly: 5 steps all doing "move X into Y" → collapse to 1. Good review produces fewer steps than input. Chat reply summarizes diff against prior version; new step list goes into file.

**Check gate dependencies before finalizing order**

For each step, identify verification gate. Ask: does that gate work right now, or does it depend on something from a later step?

If step's gate requires something from later step → that later step must come first. Order determined by what you can actually verify.

Example: "Step 1: refactor tests (gate: make llm-phoenix)" — but make llm-phoenix hangs because Step 2 fixes hang. Correct order: Step 2 first.

**Verify external assumptions before splitting — spike inline, not as future step**

If any step depends on external API capability, third-party service, or infra behavior — verify FIRST. SSH to server, call sandbox API, check docs, run CLI. Don't create steps assuming an API supports something without confirmation. Split built on unverified assumption (e.g. "Namecheap supports ALIAS via API") wastes all downstream time.

**Spikes belong in splitting session.** If "does flag X work with flag Y" and CLI is installed, answer is 30 seconds away — run it now, fold result into step (concrete flag values, no "spike protocol"), delete "Step N: spike to determine X". Future-spike step = deferred decision wearing step-shaped costume; implementer inherits same uncertainty with less context. Run command, write answer.

Test: if you can verify assumption with single shell command or HTTP request, do it during split. Reserve "spike step" for genuinely expensive verification — multi-hour load tests, third-party access you don't have, behaviour only showing up under production traffic.

**No deferred decisions inside a step**

Every step must contain only decided things. If decision is left open in plan, it'll be re-litigated mid-impl by agent with less context. Sweep step for these phrases and decide before finalizing:

- "optional X" → ship it or cut it
- "or similar", "or equivalent", "something like" → pick exact name/path/value
- "TBD", "decide later", "Phase N concern" (when Phase N is this plan) → decide now
- "may want to", "might need to", "could also" → either in step or isn't
- "for absolute safety", "if profiling surfaces" → ship safety check or don't mention it
- "If/when X lands, we'll Y" → if X is out of scope, drop the sentence
- "escape hatch for future hooks/callers" → cut. Add flag when future hook ships.

Exception: hedging about historical facts ("`--setting-sources project` was chosen presumably to isolate X") is fine — accurate uncertainty about the past, not deferred decision about future. Test: "does this defer a decision the implementer will have to make?" If yes, decide now.

Applies to surrounding doc too. Sweep whole doc for same phrases when finalizing step.
