# Jev round 3: results and two open decisions

This is for another session to review. It belongs to Draft
`harden-developer-handoff`, which is still **not approved**. The full numbers
are in `jev-calibration.md` in this folder. The scripts and raw answers are in
`jev-probe/`, and copies of the Jev docs are in `jev-docs-2026-09-23/`.

> Historical Draft note: the approval status above was written before approval. The Intent was approved on 2026-09-23T17:06:16Z; see `approval.md`.

## Where the Reviewer sits in each attempt (unchanged)

1. The Developer works.
2. Stop verification runs the tests.
3. Jev reads the Developer's final message. A clear objection stops the Build
   here and returns it to Shaping.
4. The declared targets run.
5. A fresh Reviewer runs once, last, and alone decides acceptance or rework.

The Reviewer never runs before verification and never runs twice in one
attempt. A new attempt after rework gets a new fresh Reviewer, as today.

## What the Jev guide changed

The Shaper's `jev-guide` (README and COOKBOOK) and the official docs
(jaggedness, confidence, citation check, line-by-line search, self-consistency)
say:

- Ask one narrow judgment per question.
- Jev reads literally, so state the exact condition and the boundary cases in
  the criteria.
- Give confusable outcomes their own options, including "unclear".
- Point Jev directly at the evidence, and keep unrelated text out.
- Confidence describes the shape of the distribution; it does not prove the
  answer is correct.

## Result 1: reading the Developer's message works well (v2)

For each scenario, one question asks for the state of the Developer's own work.
It is a Choice with six options:

- `unfinished`: work the Developer owns is still missing or partial.
- `done`
- `pending_external`: the Developer's work is done, and only verification,
  review, a live run or approval owned by someone else remains.
- `resolved_or_historical`: the incompleteness is in the past or was fixed.
- `objection_only`
- `unclear`

For each scenario, risk and finding, a second question asks whether there is an
objection: `objection`, `no_objection` or `unclear`. The criteria list the
exact objection forms: a change outside the guarded paths, contradicting
requirements, proof that cannot observe the behaviour, a false assumption, or a
needed Shaping decision. Unfinished work alone is not an objection.

This was tested on 294 real Developer handoffs from the records, with the
status fields hidden:

| | v1 (plain yes/no) | v2 (boundary options) |
| --- | --- | --- |
| Unfinished, confidence of 0.8 or more | 16 right, 6 wrong | 13 right, **0 wrong** |
| Wrong flags on the 108 Reviewer-rework fixture messages | 10 | **0** |
| Objections found (10 real ones) | 8, 0 wrong | 10, 1 borderline wrong at 0.80 |

The four unfinished cases v2 "missed" say "implemented, but the live
verification failed". v2 calls them `pending_external`, which is a fair
reading.

Stability, from all positives plus 40 random negatives, three runs each, plus
12 hand-written tricky messages:

- 97% of answers were identical across runs. Only low-confidence answers,
  below 0.5, ever changed.
- All 12 tricky messages were right on every run. They covered negation,
  "fixed now", non-goals, hedges, TODOs, a feature named "incomplete",
  disputed findings, and indirect and mixed objections.
- Objections, per run: at 0.8 there were 2 wrong stops. **At 0.85 there were 0
  wrong stops and 29 of 30 were caught.** At 0.9 there were 0 wrong stops and
  26 of 30 were caught.
- Unfinished, per run, at 0.8: 37 right and **0 wrong**.

## Result 2: judging code from the diff does not work, so it is dropped

Three designs were tried:

1. **The whole diff:** close to chance.
2. **Per scenario, with sub-questions:** it never falsely said "done", but its
   "not done" was wrong about one time in three.
3. **The official citation-check pattern** (split the diff into hunks, locate
   the hunk for each `then` sentence, then judge supports / contradicts / says
   nothing): worse, with 12 false "done" answers. The Reviewer's rework is
   about completeness, controls and edge cases, which a single hunk cannot
   show.

Large Intents also hit Jev's size limit: HTTP 400 with `max_tokens_exceeded`.

## Proposed design

- Kogen code builds the handoff report, so its format can never fail.
- The Developer writes free text.
- Jev reads only that text, in one small request, using the v2 questions.
- An objection at or above the threshold stops the Build and returns it to
  Shaping, quoting the Developer's words and Jev's confidence.
- Every other answer, including `pending_external`, lower-confidence
  answers and "Jev unavailable", reaches the Reviewer as a labelled note.
- A missing test file is unfinished work, decided by code.
- Jev never judges code and never accepts anything.

## Decision 1: objection threshold

**Recommendation: 0.85, raised from 0.8.** At 0.85 there were 0 wrong stops and
29 of 30 objections caught. At 0.8 there were 2 wrong stops.

## Decision 2: what an "unfinished" answer does

With v2 it is now reliable: 0 wrong at 0.8 across all runs.

- **Option A (recommended):** at 0.85 or more, Build sends the work straight
  back to the same Developer, quoting its own words, without Review this
  attempt. This uses one outer attempt, as a Reviewer rework would, and saves
  a Review turn. The next attempt still ends with a fresh Reviewer.
- **Option B:** keep it as a note for the Reviewer only (the current Draft).

## Limits

- The truth labels are imperfect. The objection labels were read by hand by
  the Shaping Controller.
- Only 10 real objections and 17 unfinished messages were available.
- The messages were rebuilt from old JSON claims, not real free text.
- One model version (`jev-1.13.0`, pinned). TypeSafe says limits may change.
- Every Jev request and answer will be kept in the records, so the thresholds
  can be re-checked after more Builds.

## Outcome (recorded after review, 2026-09-23)

The Shaper relayed the reviewing session's answers, and both were applied to
the Draft:

- **Decision 1:** the objection threshold is **0.85**.
- **Decision 2:** option **B**. "Unfinished" stays a note for the Reviewer.
  Automatic rework can be turned on later by changing one constant, once real
  free-prose Builds confirm it.
