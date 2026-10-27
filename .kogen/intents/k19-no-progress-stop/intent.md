# Stop an external Build that makes no progress

Slug: k19-no-progress-stop
Model: not applicable — the change is one counter inside the existing Build round loop; the Build state machine is otherwise unchanged.
Acceptance:
- .kogen/intents/k19-no-progress-stop/acceptance.feature
- features/steps/k19_no_progress_steps.js
- features/steps/k19_no_progress_driver.go

A Build driven by an external executor (`executor: claude-code`) stops early when its builder keeps finishing with the same red result, instead of burning every remaining round up to `max_rounds`.

Rule. After each Kogen verification pass of an external Build (the whole-Intent pass, and a staged scoped gate with its stage id as part of the identity) Kogen computes a fingerprint of the pass's failing set: the failing item names (checks, `acceptance`, `model`), the failing scenario/test identifiers and the bounded failure text exactly as already recorded for the pass and sent as feedback, but without the pass number. The fingerprint is a stable string (a SHA-256 hex digest of that content is fine). A pass extends the current streak when it is red, clean (no moved files), has a nonempty failing set, its fingerprint equals the streak's, and its candidate tree (the verified tree after the fixers ran) equals the streak's tree, so the candidate changed by nothing beyond what fixers produce, or the builder made no edit. Otherwise a red pass starts a new streak of 1, and a green pass or any pass that is not clean or has no failing items clears the streak. When a streak reaches 3, Kogen records exactly one run-log event `{"event":"executor_no_progress", "rounds": <builder rounds run so far>, "fingerprint": <string>, "failing": [<the failing item names of the pass>]}` and stops with `candidate/executor_round_limit` (the same error, exit 1 and outcome `executor_round_limit` as the round cap), leaving the candidate in place exactly as the cap does. The event is written before the outcome event. 3 is a shared constant, not a setting. The check runs in the external round path of `drive` after the K16 blocker handling (`afterExternalRound`, which stays first and unchanged) and after the round's fixers and verification, and before the `max_rounds` test, so a third identical pass that coincides with the cap still records the event. Passes made after a review repair (a green pass whose reviewed tree changed, then verified again) are ordinary passes for the count.

Boundaries. Native builds are unchanged: a native Build never records the event or stops on it, and the native `candidate/no_progress` rule is untouched. No new timeout, retry, setting or round limit; `max_rounds` is unchanged; the streak is held in memory (like the native watch) and an external checkpoint still cannot be resumed.

Documentation. Extend the external-executor description in `spec/prose/04-building.md` (LOOP-14, after the `max_rounds` sentence: the Build also stops with `candidate/executor_round_limit` after recording `executor_no_progress` when three consecutive passes have the identical failing-set fingerprint over an unchanged candidate tree; any change or a green pass resets the count; native unchanged), `docs/executor-contract.md` (the `max_rounds` row and stop text) and `docs/configuration.md` (the `max_rounds` bullet). Leave `spec/features/04-building.feature` unchanged; `sh check.sh` in `spec/` must still pass.

## Decisions
- External Builds stop after 3 consecutive identical-fingerprint red passes over the same candidate tree, with `executor_no_progress` then `candidate/executor_round_limit` (source: request)
- The count resets when the failing set or failure text changes in any way, the tree changes, or a pass is green (source: request)
- Native builds are unchanged and the constant 3 is not configurable; K16 blocker handling runs first and is unchanged; `max_rounds` is unchanged (source: request)

## Source comparison
- Fingerprint of check names, failing scenario/test identifiers and bounded failure text: addressed (Rule; the pass's recorded failing items and feedback text, minus the pass number).
- 3 consecutive identical passes with an unchanged tree beyond fixers, or no builder edit: addressed (Rule: same post-fixer verified tree). The reading of "nothing beyond what fixers produce" as equal post-fixer tree is a shaping decision.
- One `executor_no_progress` event with rounds, fingerprint, failing items, then `candidate/executor_round_limit`, candidate left in place: addressed (Rule; scenarios 1 and 3).
- Reset on any change or green: addressed (scenarios 2 and 3).
- Native keeps its rule; spec wording extended for the external path; no new timeout, retry or setting; round cap and K16 unchanged: addressed (Boundaries, Documentation).
- The request's "native LOOP-14" no-progress behaviour is the existing native `candidate/no_progress` rule of LOOP-7 in this repository; left untouched (conflicting naming, no behaviour change).
- Acceptance: fake external builder with no edits against a red check stops after the third pass (scenario 1); changing failing text is not stopped early (scenario 2); green resets (scenario 3); all configured checks pass (the Build's normal gate). Host safety: only a scripted in-process fake executor, never the real claude binary, no process killing.

## Tests
- Third identical red pass stops an external Build with the event and the round-limit stop before the cap: add cli/build tests with the fake executor, and the acceptance scenario (integration)
- Changed failing text, changed tree or a green pass resets the count: add cli/build tests, and the acceptance scenarios (integration)
- Native builds are never stopped by the new rule: existing noprogress tests plus one native case that repeats the same red three times with tool calls and is not stopped by it (integration)
- Existing external round-cap tests keep passing (TestExternalRoundLimit*): update only where the identical red now stops at the third pass (existing)
- End to end through the real Build with a fake external executor: the acceptance scenarios (scenario)

## Feasibility
- evidence: {"id":"k19-observer","kind":"observer","inputs":["features/steps/k19_no_progress_driver.go"],"observers":["features/steps/k19_no_progress_steps.js","features/steps/k19_no_progress_driver.go"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/k19_no_progress_steps.js --control good","exit":0,"output":"k19 observer good\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/k19_no_progress_steps.js --control bad","exit":1,"output":"k19 observer rejected bad fixtures\n"}]}
- The driver compiles and runs on the unchanged tree, reaches the real Build over the fake executor and observes the old behavior (no event, 8/5/8 rounds) in all three modes. (probe 1: exit 0, 8.0 s)
