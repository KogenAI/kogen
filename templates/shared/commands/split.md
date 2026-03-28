---
description: Split work into shippable steps where each commit keeps the system functional
argument-hint: [description of work to split, or reference to a plan/doc]
---

Analyze the work described (or the current plan/document if no argument given) and split it into discrete, independently shippable steps if possible. Some work is too tightly coupled to split meaningfully — if that's the case, say so and explain why rather than forcing an artificial split.

Each step must:

- Leave the system in a better state than before — not just functional, but genuinely more valuable even if no further steps are ever shipped
- Be a coherent unit with a clear purpose (not just "schema", but "schema that enables X")
- Be as small as possible while still being meaningful
- Have a one-line "why this is valuable on its own" justification — not just "system still works" but "here's what you gain"

Think of steps as building blocks stacked on top of each other. Step 1 alone is an improvement. Step 1 + 2 is better. Step 1 + 2 + 3 is the full feature. You should be able to stop at any step and have shipped something worthwhile.

Principles for splitting:

- **Additive before behavioral** — schema changes, new modules, and new functions with no callers ship first; logic changes that use them ship after
- **Infrastructure before wiring** — add the plumbing before turning on the tap
- **Isolate external dependencies** — Stripe, email, third-party APIs should be wired up in their own step so they can be tested independently
- **Cleanup last** — removing old fields, deprecated functions, or feature flags ships after the replacement is live and verified
- **Prefer fewer, meatier steps** — don't split for the sake of splitting; a step that only adds a migration with no callers is noise unless the migration itself is risky

Output format — for each step:

```
## Step N — [short name]

**What:** One sentence describing what changes.
**Value if we stop here:** One sentence on what's gained even if the next step is never shipped.

[List of specific files/functions/migrations to change]
```

Steps are **sequential commits on a single branch** — not parallel branches or PRs. Each step is implemented and committed before the next begins. "Merge candidate" suggestions are appropriate only when two steps touch the same code and separating them would require editing the same lines twice in consecutive commits — in that case, say so explicitly and merge them into one step.

If the work was already split (e.g. in a plan document), review the existing split and suggest improvements — merging steps that are too granular, splitting steps that do too much, or reordering steps that have hidden dependencies.

**Critical: Check gate dependencies before finalizing order**

For each step, identify its verification gate (how you confirm it's done — running tests, a make target, an end-to-end check). Then ask: does that gate actually work right now, or does it depend on something from a later step?

If a step's verification gate requires something from a later step, that later step must come first — even if it feels like a dependency inversion. The order is determined by what you can actually verify, not just what implements what.

Example: "Step 1: refactor tests (gate: run make llm-phoenix)" — but make llm-phoenix hangs because Step 2 fixes the hang. Correct order: Step 2 first, then Step 1.
