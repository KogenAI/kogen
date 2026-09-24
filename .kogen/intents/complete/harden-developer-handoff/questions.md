# Decisions and open questions: harden-developer-handoff

Status: **Approved** by the Shaper on 2026-09-23T17:06:16Z (see `evidence/approval.md`).

## Current design (after the Jev revision)

1. Kogen code builds the handoff report and stores it under the attempt's
   `handoff` key. Handoff format and schema cannot fail.
2. The Developer writes free prose. No Kogen code parses it; only Jev reads it.
3. Jev (`jev-1.13.0`) answers the v2 questions in one request: a six-option
   `status` per scenario and a three-option `objection` per item.
4. If an objection answer reaches 0.85 or higher, the Build stops and
   returns to Shaping, quoting the Developer's words and Jev's confidence.
5. Everything else goes to the fresh Reviewer, including Jev's notes
   (labelled advisory) and "Jev unavailable". The Reviewer alone decides
   acceptance or rework.
6. A missing declared proof selector is unfinished work, decided by code, and
   leads to rework.

## Decisions the Shaper made in this conversation (2026-09-23)

1. **Deterministic code produces everything it can.** The Shaper said: "we
   gotta put as much deterministic scripts/code as we can instead of relying
   on non-deterministic llm". Handoff format and schema must be guaranteed.
2. **A missing proof selector is unfinished work, and leads to rework.**
3. **A Reviewer finding the Developer cannot address is a cannot-comply
   case.** There is no separate `blocked` status.
4. **The first relayed review's points were accepted.** They are: accept the
   weaker self-assessment deliberately, and make Review own completeness;
   treat this as a contract change across the whole pipeline and size it
   honestly; state that `affected_paths` shows which files changed, not where
   each behaviour lives.
5. **Cannot-comply stops the Build and returns to Shaping.** The second
   relayed review confirmed it: "A Developer can't fix a wrong contract by
   trying again."
6. **The second relayed review's fixes were applied.** The guard hook is not
   editable. The objection leads the error even when verification was
   exhausted. The report flags scenarios whose affected paths did not change.
7. **Both live targets are selected.** `live-shape-to-build` was added (option
   A, about 4 paid minutes), because `live_shape_to_build_test.exs:572` decodes
   the removed schema. The report stays under the existing `handoff` key.
8. **The Jev revision** (`.kogen/runtime/shaping-followups/SHAPE_HANDOFF_JEV.md`).
   Jev is the reader of the Developer's handoff prose. The signal command is
   dropped. Cost is not a concern.
9. **Sending Kogen code to TypeSafe is acceptable.** The Shaper: "yes it's ok
   to send kogen's code I don't care". Zero data retention is enterprise-only,
   and TypeSafe does not train on requests.
10. **Keep one Intent; do not split.** The Shaper disagreed with splitting
    Jev out. Calibration then shrank Jev's part to one small request with a
    fixed mapping from answers to outcomes, and the Controller now agrees.
11. **When Jev fails, the Build goes to Review with "Jev unavailable"
    noted.** The Shaper: "I agree."
12. **Cannot-comply stops at a threshold of 0.8 (superseded by 16).** The Shaper agreed to the
    Controller's design points 1–4, including this one. The value comes from
    `evidence/jev-calibration.md`: 8 of 10 real objections caught and 0 wrong
    stops in 294 messages. At 0.9, half would be missed.
13. **Unfinished answers are advisory only, and go to the Reviewer.** Jev was
    wrong about one time in four with high confidence, so no threshold makes
    it safe for routing. The Shaper confirmed that Jev's notes go to the
    Reviewer.
14. **The Shaper confirmed that no acceptance ever skips the Reviewer.** The
    only thing Jev can do on its own is stop the Build and send it to Shaping.
15. **The third relayed review's additions were applied.** The Developer is
    asked to state objections plainly. The stop message quotes the
    Developer's words and Jev's confidence. The threshold (now 0.85, see 16) is a named constant tied to
    the evidence, and every Jev request and response is retained so it can be
    re-checked. `max_tokens_exceeded` takes the unavailable path, with a test.

16. **The objection threshold is 0.85, superseding 0.8.** Round 3 used v2
    questions with boundary options, designed from the Shaper's Jev guide and
    the official docs. At 0.85 there were 0 wrong stops and 29 of 30 caught;
    at 0.8 there were 2 wrong stops. This was relayed as agreed by the
    Shaper's reviewing session.
17. **"Unfinished" stays advisory (option B).** It was 0 wrong at 0.8 in
    round 3, but it rests on few positives, rebuilt from JSON claims. A wrong
    route would burn one of two outer attempts, while a wrong stop is visible
    and cheap. Automatic rework can be enabled later by changing one constant.
    This was relayed as the Shaper's reviewing session's recommendation.

18. **A missing Jev key stops the Build before launch** (refining 11). The
    Shaper agreed with the review: "I agree with the review". A missing
    Keychain item `ai.typesafe.api` is treated like a logged-out harness, and
    the precondition checks only that the item exists, without reading it.
    Runtime Jev failures (timeouts, transport errors, 401, rate limits,
    `max_tokens_exceeded`, malformed answers) still go to Review marked "Jev
    unavailable". This is noted, not blocking: both paid targets now depend on
    TypeSafe being up.

19. **README update, including the Jev Keychain requirement** (continuation
    visit, 2026-09-23). The Controller found that `README.md` is on the guarded
    list but no scenario required updating it, and "The loop" would contradict
    the new behaviour. The Shaper accepted adding the fix to
    `reviewer-owns-completeness` as documentation only, with no scope change.
    The reviewing session the Shaper relayed added that the README must also
    document the `ai.typesafe.api` Keychain requirement, so that anyone
    running `mix kogen.build` on another machine knows why the precondition
    stops.

## Rejected or superseded approaches, with evidence

- **A Developer-written JSON handoff with free correction turns.** Replaced by
  a report built by code.
- **Enforcing JSON on Claude with `--json-schema`.** It was unreliable when
  Stop answers `already terminal` (`evidence/stop-terminal-probe.md`).
- **The signal command (`unfinished` / `cannot-comply`).** Replaced by Jev
  reading the prose (decision 8).
- **Jev judging implementation from the diff.** Two probe designs were tried.
  Whole-diff judging was right on 14 of 25 answers and nondeterministic.
  Per-scenario judging with sub-questions and repeats was more stable and
  never wrongly said "done", but its "not done" was wrong about one time in
  three, and large Intents hit `max_tokens_exceeded`
  (`evidence/jev-probe.md`, `evidence/jev-calibration.md`). This is left out
  of the Intent. A third design, the official citation-check pattern (split
  the diff into hunks, locate the hunk for each `then` sentence, then judge
  supports / contradicts / says nothing), was worse: 12 false "done" answers
  (`evidence/jev-calibration.md`, round 3).
- **Letting Jev route "unfinished" straight to rework.** Rejected for now
  (decisions 13 and 17).
- The completed Intent `structured-developer-handoffs` ("Retain current
  bounded outer rework for settled invalid handoffs") is superseded, because
  no Developer-authored structured handoff remains. That package is historical
  and is not edited.

## Size and split fallback

This is one full Build. The old schema code stays in place, unused, and
deleting it is a follow-up Intent. If the Build proves too large, the
fallback split is:

- **A:** the controller report, schema-free turns, the prompts and the
  missing-selector rule, with the Reviewer reading the prose directly.
- **B:** the Jev client, the objection stop and the advisory notes.

## Known leftover until the cleanup Intent

The standalone `live-general` Reviewer challenge
(`test/kogen/live_test.exs:119-143`) and its rehearsal
(`test/kogen/scenario_semantic_test.exs:55,69`) build an old-shape handoff
with `Contract.handoff` for their own prompt. They do not run through Build,
and they keep passing because `Contract.handoff` stays in place.

## Non-goals

- Jev judging code or tests, and Jev anywhere else: the Shaping audit,
  Reviewer citation audits and helper routing.
- A provider-neutral evaluator layer, and Lean or other formal verification.
- Stop-hook changes and report-only correction turns.
- Deleting the old schema and validator code and their tests (follow-up
  Intent).
- The `KOGEN_ROLE=developer` leak and the `offline.py` selector rendering bug
  (separate follow-ups).
- Why `check` passed without the scenario behaviour, which is a question of
  Shaping quality.
- Migrating or rewriting retained records.
- New paid targets and new configuration keys. The Jev model, endpoint,
  timeout, retry count and 0.85 threshold are named code constants.

## Open questions

None.
