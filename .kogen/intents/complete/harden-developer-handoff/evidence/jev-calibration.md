# Jev calibration probes (23 September 2026, round 2)

The Shaper asked for a threshold investigation and better probes of judging
from the diff. All calls used real `jev-1.13.0`. The scripts and raw answers
are in `jev-probe/` (`prose_calibration.py`, `tricky_prose.py`, `diff_v2.py`
and their `.json` results). No key material is retained.

## 1. Reading Developer prose: 294 real handoffs

**Method.** The probe took every unique Developer handoff message in the
retained records: 294 messages, 1,573 scenario entries (132 of them
`incomplete`), plus risks and findings. It rewrote each message as prose ("Scenario X:
<claim>", "Risk Y: <response>") **with the status fields removed**, and asked
per item: `unfinished` (scenarios) and `cannot_comply` (every item). There
were 0 transport errors.

**Truth labels.** For `unfinished`, the label is the Developer's own hidden
status. For `cannot_comply`, a keyword regex was used first; it missed most
real objections, so the objection labels were then assigned by the Shaping
Controller reading every flagged entry. Ten messages hold a real contract
objection: 1vg5QEsj #0, 2xt-TMNZ #1, Bg1qobsC #1 and #2, LUPXtmoI #1,
QpZjQahd #0, VZFIeCIg #0, _3Vw8AoaI #0, hIhZhNA3 #2, and dEkBAojD #2 (a
blocked finding). Ij_SIvWe #0 says "Blocked/Incomplete" about unfinished work,
which is not an objection.

**Per message, what Build would do.** An objection is flagged when any item's
`cannot_comply` answer is "yes" at or above the threshold:

| Threshold | Builds stopped | Correct | Wrong | Objections missed |
| --- | --- | --- | --- | --- |
| 0.5 | 10 | 9 | 1 (Ij_SIvWe, 0.71) | 1 |
| 0.7 | 9 | 8 | 1 | 2 |
| **0.75–0.85** | **8** | **8** | **0** | **2** (LUPXtmoI 0.59, dEkBAojD 0.28) |
| 0.9 | 5 | 5 | 0 | 5 |

The best range for `cannot_comply` is **0.8**, with no wrong stops in 294
messages. At 0.9, half of the real objections are missed.

**Unfinished, per message.** 108 messages come from the live Reviewer-rework
fixture and are excluded, and so are the objection messages, which stop first.
That leaves 176 messages, 17 of them truly unfinished.

| Threshold | Rework routed | Correct | Wrong | Missed |
| --- | --- | --- | --- | --- |
| 0.5 through 0.9 | 22 | 16 | **6** | 1 |
| 0.95 | 20 | 16 | 4 | 1 |

- **No threshold separates the errors.** Jev is confident (0.9–1.0) even on
  the wrong ones. Some of those are label noise, where the Developer marked
  the item `ready` while writing "X remains required". Others are misreadings,
  such as "remains incomplete historical evidence" or "Corrected the ...".
  Routing `unfinished` straight to rework would waste an attempt on correct
  work in roughly one case out of four.
- The Reviewer-rework fixture tells the Developer to leave a file
  "intentionally absent" before the first Review. Jev reads 10 of those 108
  messages as unfinished, so automatic routing would also break that paid
  fixture unless its wording changed.

## 2. Hand-labelled tricky phrasings (12 notes × 3 repeats)

These covered negation, "was incomplete, now finished", a feature named
`incomplete`, non-goals, hedges, "did not get to X yet", terse TODOs, disputed
findings, blocked environments, and indirect, contradictory and mixed
objections.

- Every true `cannot_comply` was caught. The one wrong "yes" was at 0.25–0.47,
  below any sensible threshold.
- Every true `unfinished` was caught. The wrong "yes" answers fell into two
  groups. Items carrying an objection were also read as unfinished (0.58–0.98),
  which is harmless because `cannot_comply` takes precedence. The other wrong
  answers were at 0.5 confidence or lower.
- Repeats of the same request were stable on these notes.

## 3. Judging from the diff, version 2 (per scenario, 93 cases × 3 repeats)

**Method.** One request per (Candidate, scenario). The state held the scenario
text, the diff restricted to that scenario's concrete `affected_paths` code
files, and the diff of its declared offline test files. Three questions were
asked: `then_implemented`, `wrong_result_present` and `test_asserts_then`.
Truth was the Reviewer's per-scenario verdict, or the Developer's own
`incomplete`. The cases covered rehearsed-verification-plan (10 Candidates),
named-routes and harden-whole-test-suite.

- **Size.** 30 of 279 requests (all harden-whole-test-suite, 415–543 KB)
  failed with **HTTP 400 `{"detail":{"error_type":"max_tokens_exceeded"}}`**.
  This status is undocumented. The largest request that succeeded was 83 KB,
  about 23k tokens.
- **Stability improved over version 1.** `then_implemented` gave the same
  answer on all 3 repeats in 76 of 83 cases, and `wrong_result_present` in 82
  of 83.
- **It never wrongly said "done":** 0 false "satisfied" answers at any
  threshold.
- **"Not done" is often wrong.** With a majority vote over the three
  repeats:

| Threshold | "done", correct | "not done", correct | "not done", wrong | No answer |
| --- | --- | --- | --- | --- |
| 0.0 | 16 | 37 | 19 | 11 |
| 0.8 | 1 | 10 | 4 | 68 |
| 0.9 | 0 | 7 | 2 | 74 |

- **Conclusion.** Judging from a diff is better than version 1 but still not
  good enough to route work. It is conservative and rarely answers with high
  confidence. It could be an advisory hint for the Reviewer, but it adds
  packet sizing and splitting while the Reviewer inspects the code anyway.

## Limits

Truth labels are imperfect, and the objection labels are the Controller's own
judgement. The prose was reconstructed from old JSON claims rather than future
free prose. Positives are few: 10 objection messages. One host and one model
version were used, and the docs say limits and behaviour may change.

# Round 3: after studying the Jev guide and the official docs (23 September 2026)

The sources were the Shaper's `jev-guide/README.md` and `COOKBOOK.md`, and the
official confidence, primitives, jaggedness, citation-check, line-by-line
search, self-consistency and re-ranking pages. Copies fetched on 2026-09-23
are in `jev-docs-2026-09-23/`. The guidance that shaped this round:

- One narrow judgment per question.
- State the exact condition and the boundary cases in the criteria, because
  Jev reads literally.
- Give confusable outcomes their own options, including an "unclear" option.
- Point Jev directly at the relevant evidence.
- Keep irrelevant material out of the state.
- A confidence value is the shape of the answer distribution, not proof that
  the answer is correct.

## Prose v2 (`prose_v2.py`): explicit boundary categories

A per-scenario `status` Choice was asked, with six options: `unfinished`,
`done`, `pending_external` (the Developer's work is complete and only
verification, review, a live run or approval owned by someone else remains),
`resolved_or_historical`, `objection_only` and `unclear`. A per-item
`objection` Choice was also asked, with the options `objection`,
`no_objection` and `unclear`. The criteria list the exact objection forms, and
a rule says that unfinished work alone is not an objection. The same 294
messages were used.

| Outcome, per message | v1 | v2 |
| --- | --- | --- |
| Unfinished at 0.8 (176 non-fixture, non-objection messages; 17 marked incomplete) | 16 correct, **6 wrong**, 1 missed | 13 correct, **0 wrong**, 4 missed |
| Reviewer-rework fixture messages wrongly flagged unfinished | 10 of 108 | **0 of 108** |
| Objection at 0.8 | 8 correct, 0 wrong, 2 missed | 10 correct, 1 wrong (Ij_SIvWe, borderline "Blocked ... would contradict the Approved Intent"), 0 missed |

The four v2 "misses" are Developers who wrote "implemented, but the
Stop-owned live verification failed or is unsettled". Jev put them in
`pending_external`, which fits the Developer's own work being complete.

## v2 repeats (`prose_v2_repeat.py`)

The run covered all positives and 40 random negatives, three runs each, plus
the 12 tricky notes three times each.

- 1,309 of 1,346 questions gave the same choice on all three runs. Every
  question that changed stayed below 0.5 confidence.
- **Objection, per run:** at 0.8 there were 2 wrong stops and 0 misses (out of
  30 positive runs). **At 0.85 there were 0 wrong stops and 1 miss**, the
  blocked finding dEkBAojD #2 at 0.82–0.85. At 0.9 there were 0 wrong stops
  and 4 misses. The true objections scored between 0.82 and 1.0.
- **Unfinished, per run:** at 0.8, 37 correct, **0 wrong**, 14 missed (mostly
  `pending_external`). The results were the same at 0.85 and 0.9.
- **Tricky notes:** all 12 were right on all three runs, at 0.8, for both
  questions.

## Diff judging v3 (`diff_v3.py`, `hunks.py`): citation-check pattern

Code split the diff into ID-tagged hunks and the scenario's `then` into
clauses. One request located the hunk for each clause, and asked a Noul
whether any hunk implements it. A second request, per clause, judged the
located hunk against the clause and the scenario's `wrong_result` as
supports, contradicts or says nothing.

- 75 of 93 cases ran. 10 were too large (over 100 KB of hunks), and 8 had no
  hunks in their concrete paths.
- The results were **worse than v2**. At 0.8, "done" was right 16 times and
  **wrong 12 times**. "Not done" was right 8 times and wrong 3 times, and 36
  cases got no answer. A hunk that "supports" a clause usually exists even
  when the Reviewer later demanded rework. Reviewer rework findings concern
  completeness, controls and edge cases, which a clause-to-hunk relation
  cannot see.
- **Conclusion:** after three designs, judging implementation from a diff
  remains unsuitable for Jev in this workload. Only reading the Developer's
  prose is reliable.
