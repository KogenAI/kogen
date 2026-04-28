---
description: Split work into shippable steps where each commit keeps the system functional
argument-hint: [description of work to split, or reference to a plan/doc]
---

Analyze the work described (or the current plan/document if no argument given) and split it into discrete, independently shippable steps if possible. Some work is too tightly coupled to split meaningfully — if that's the case, say so and explain why rather than forcing an artificial split.

**Default the answer to one commit, then justify each additional split.** The user invoking `/split` is a strong prior toward N>1, but it is not proof. Many design docs describe one intent expressed across many files — landing them as N commits produces a half-migrated codebase between commits, N× the CI runtime, N× the review overhead, and a revertability that's almost never used because the intermediate states aren't viable to ship-and-stop on. Before producing any step list, write down "could this be one commit?" and answer it honestly. If the answer is yes or maybe, the result is one step (or a clear "this is one intent, not splittable" reply that updates the doc accordingly). Only produce N>1 when each additional step ships strictly more value than just being part of the whole — e.g. an independent bug fix, a piece of infrastructure that's useful before the rest lands, an external dependency that benefits from isolation. "Each commit is smaller" is not a reason; smaller commits at the cost of half-migrated intermediate states is worse, not better.

The strongest signal that work is one commit, not N: every candidate step boundary fails either the scaffold test or the regression test below. When that happens, write the plan as a single step and explain in a `## Why one commit, not N` section why every candidate boundary failed. The user can override; the default is honest.

**Where the split lives: in the document, not in chat.**

If the argument references an existing plan/doc (a file path, `@path`, or unambiguous reference to a doc you've just read), the split IS that document's implementation plan. Edit the file in place — replace the existing implementation-plan/phases/steps section with the new step list. Do not paste the full step list into chat. After writing, reply with a short summary only: how many steps, what changed from the prior version (merges, reorderings, cuts), and any open questions. The user will read the steps in the doc.

If there is no source document (the argument is a free-form description of work with no doc backing it), ask the user where to write the plan before producing the steps — typically a new file under `codegen/` or `docs/`. Do not default to dumping the plan into chat. Only when the user explicitly asks for a chat-only response (e.g. "just tell me, don't write it down", "preview only") should the steps appear inline in the reply.

When reviewing or updating an existing split document, if you reorder steps you MUST rewrite the document to reflect the new order — do not just say "do them in this order" in chat. The same rule applies: numbers in the document are the ground truth.

Each step must:

- Leave the system in a better state than before — not just functional, but genuinely more valuable even if no further steps are ever shipped
- Be a coherent unit with a clear purpose (not just "schema", but "schema that enables X")
- Be as small as possible while still being meaningful
- Have a one-line "why this is valuable on its own" justification — not just "system still works" but "here's what you gain"

**Scaffold test**: before accepting a step, ask "if the next step is never shipped, does a user or developer gain anything from this?" If the honest answer is no — it's pure scaffolding that only enables the next step — merge it with the next step. A struct with a no-op function, a migration with no callers, an empty module with no behaviour — these are not shippable steps, they're half-steps. Merge them forward.

**Regression test**: the flip side of scaffold. Ask "if we stop here, is the system actually worse than before?" A step that ships visible placeholder strings in user output, blocks a previously-working path without providing the new one, writes literal `TODO_REPLACE_ME` tokens into artifacts users see, or leaves two subsystems in contradictory states (e.g. an enforcement hook that blocks action X while the rule file still tells the agent to do X) is a regression, not a step. Merge it forward with whatever step resolves the regression. The rule: every step must leave the system strictly better than the previous commit, not "better eventually once the next step lands". If stopping mid-sequence would make you want to revert, it's not a shippable step.

Common regression-half-step shapes to watch for:

- **Placeholder in output**: recipe ships `XYZ_PLACEHOLDER_URL` as a buy-button target. Without the follow-up step that scans-and-patches, users see literal placeholder text. Merge placeholder introduction with the consumer that replaces it.
- **Enforcement without guidance**: hook/guard blocks a behaviour while the prompt/rule still instructs the agent to attempt it. Agent hits the block, has no documented alternative, thrashes. Merge the enforcement with the rule rewrite that supplies the alternative.
- **Callers without implementation**: wiring a feature flag or new branch that calls a module whose real behaviour lands next step. The branch is dead or broken in production for the duration of one commit. Merge.
- **Half-migrated state**: renaming half the call sites in a commit, the rest in the next. The codebase compiles but readers see two names for the same thing. Merge or complete the rename in one commit.

Think of steps as building blocks stacked on top of each other. Step 1 alone is an improvement. Step 1 + 2 is better. Step 1 + 2 + 3 is the full feature. You should be able to stop at any step and have shipped something worthwhile.

Principles for splitting:

- **Additive before behavioral** — schema changes, new modules, and new functions with no callers ship first; logic changes that use them ship after
- **Infrastructure before wiring** — add the plumbing before turning on the tap
- **Isolate external dependencies** — Stripe, email, third-party APIs should be wired up in their own step so they can be tested independently
- **Cleanup last, but only when it needs to wait** — "cleanup last" applies to feature flags, deprecated DB fields, and code that must stay live while the replacement proves itself in production. It does NOT apply to code that becomes provably unreachable the moment its callers are removed — that goes in the same commit. Splitting caller removal from function deletion forces dead code into the codebase between steps, drops coverage on code about to be deleted, and wastes time writing tests for functions that won't exist in the next commit. Remove dead functions in the same step that removes their last caller.
- **Prefer fewer, meatier steps** — don't split for the sake of splitting; a step that only adds a migration with no callers is noise unless the migration itself is risky
- **Group identical mechanical moves** — if the same operation is repeated N times (extract handler A, extract handler B, extract handler C…), that is one step, not N. The value comes from the pattern being established, not from each individual move. Only split mechanical repetition when the moves have meaningfully different risk profiles or touch different systems.
- **Group one intent expressed across many files** — broader than mechanical-move grouping. If a design doc's whole purpose is "do X" and the implementation is "land twelve hooks + cut twelve prose blocks + add a Makefile target" because that's what "do X" means, all of that is one step. The edits are not mechanically identical (different hooks have different bodies), but the _intent_ is one thing. Splitting it produces commits with names like "land half the hooks", which can't be reverted independently in a useful way (reverting half a strategy is worse than reverting the whole thing) and forces the codebase through a half-migrated intermediate state where the prose still tells the agent to do things the new hooks block. The test: if every candidate boundary leaves the codebase in a self-contradictory state, the work is one intent, not N. Ship as one commit.

Output format — for each step:

```
## Step N — [short name]

**What:** One sentence describing what changes.
**Value if we stop here:** One sentence on what's gained even if the next step is never shipped.
**Commit message:** Imperative, under 50 chars, answers *why* not *what*. Bad: "Extract build intents". Good: "Add contact forms to static sites".

[List of specific files/functions/migrations to change]
```

Steps are **sequential commits on a single branch** — not parallel branches or PRs. Each step is implemented and committed before the next begins.

**Do not merge steps just because they touch the same code.** Two changes that edit the same lines but represent distinct functionality (e.g. "make Stripe calls return `{:error, _}` instead of crashing" and "make Stripe calls safe to retry via idempotency keys") are two steps, not one — even if implementing them sequentially means editing the same call sites twice. The cost of touching the same lines twice is small; the cost of merging unrelated intent into one commit is a muddied history, harder review, and a step that can't be reverted independently if one half regresses. Merge only when the two changes are genuinely the same intent expressed in two places (e.g. a rename that touches both the definition and all call sites — that's one step because it's one intent).

**Operational actions are not steps.** Deploys, WhatsApp messages, manual verifications, SSH commands, "trigger a rebuild", "send the connect link" — these are not numbered steps. They have no commit. If any are required after the code ships, put them in a `> **Human action required after all steps ship:**` callout at the end of the implementation plan — numbered, with the human as the explicit actor. A numbered step that produces no commit wastes a step slot and misleads future sessions into treating operational work as code work.

**Critical: step numbers ARE the execution order. No implicit ordering.**

The document is the source of truth and will be read by future sessions that have none of your context. If you decide steps should run in a different order than they're physically numbered in the document, you have two choices and only two:

1. Renumber the steps in the document so the physical order matches the execution order. This is almost always the right answer.
2. If for some reason you cannot renumber (e.g. external references already point at specific step numbers), add an explicit `> **Execution order:** N → M → ...` callout at the top of the steps section, AND add a `**Why this comes after Step X:**` note in each step whose execution order differs from its number.

Never tell the user "the steps execute in order X but I labelled them Y" in chat without writing it into the document. A future session running this document blind will follow the numbers, not your conversation. If the numbers lie, the work ships in the wrong order.

If the work was already split (e.g. in a plan document), review the existing split and apply improvements directly to the document — merging steps that are too granular, splitting steps that do too much, or reordering steps that have hidden dependencies. Be willing to cut the step count significantly: if the plan has 5 steps that all do "move X into Y", collapse them into 1. A good review should produce fewer steps than the input, not the same number with minor edits. The chat reply summarizes the diff against the prior version; the new step list goes into the file.

**Critical: Check gate dependencies before finalizing order**

For each step, identify its verification gate (how you confirm it's done — running tests, a make target, an end-to-end check). Then ask: does that gate actually work right now, or does it depend on something from a later step?

If a step's verification gate requires something from a later step, that later step must come first — even if it feels like a dependency inversion. The order is determined by what you can actually verify, not just what implements what.

Example: "Step 1: refactor tests (gate: run make llm-phoenix)" — but make llm-phoenix hangs because Step 2 fixes the hang. Correct order: Step 2 first, then Step 1.

**Critical: Verify external assumptions before splitting**

If any step depends on an external API capability, third-party service feature, or infrastructure behavior — verify it FIRST. SSH to the server, call the sandbox API, check the docs. Do not create steps that assume an API supports something without confirmation. A split built on an unverified assumption (e.g. "Namecheap supports ALIAS via API") wastes all time spent on every downstream step that depends on it.

**Critical: No deferred decisions inside a step**

Every step must contain only decided things. The implementation cycle (planner → developer → verification) goes all the way to the code level — if a decision is left open in the plan, it'll be re-litigated mid-implementation by an agent that has less context than the planner did. Sweep the step for these phrases and force a decision before finalizing:

- "optional X" → ship it or cut it. "Optional" is what humans write when they haven't decided.
- "or similar", "or equivalent", "something like" → pick the exact name/path/value.
- "TBD", "to be decided", "decide later", "we'll figure out", "Phase N concern" (when Phase N is this same plan) → decide now.
- "may want to", "might need to", "could also", "if we want to" → either it's in the step or it isn't.
- "for absolute safety", "if profiling surfaces" → either ship the safety/profile check or don't mention it.
- "If/when X lands, we'll Y" → if X is out of scope, drop the sentence; the future plan will own Y.
- "escape hatch for future hooks/callers" → cut. Add the flag when the future hook ships.

The exception: hedging about _historical_ facts ("`--setting-sources project` was chosen presumably to isolate X") is fine — that's accurate uncertainty about the past, not a deferred decision about the future. The test is "does this defer a decision the implementer will have to make?" If yes, decide now.

This applies to the surrounding doc too, not just the step block. A "Decisions Log" or "Proposed Changes" section riddled with hedges leaks into implementation. When you finalize the step, sweep the whole doc for the same phrases.
