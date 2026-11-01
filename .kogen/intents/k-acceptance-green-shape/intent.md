# Restore shaping and review acceptance

Slug: k-acceptance-green-shape
Model: not applicable — restores existing specified lifecycle behavior without adding a new state machine; the existing specification models remain authoritative
Acceptance:
- .kogen/intents/k-acceptance-green-shape/acceptance.feature
- features/steps/acceptance_green_shape_steps.js

Restore the six installed-release cases identified below. The specification and its scenarios are the source of truth, not current implementation behavior. Diagnose implementation drift and repair it without new commands, flags, options, timeout, retry or limit changes. Do not skip, weaken, tag out or retry scenarios. Other pre-existing failing cases are a separate item. No recorded behavior-changing decision was supplied or established in this investigation: the listed scenarios stand. Changes to specification or scenarios require an identified recorded decision, not an inference from current code.

## Decisions
- Preserve all existing scenario outcomes and installed-release boundaries. (source: request)
- Run the six selected cases three times, then the complete non-live suite once; report totals and allow no previously passing scenario to regress. (source: request)

## Source comparison
- Addressed: request K-ACCEPTANCE-GREEN-SHAPE-REVIEW, fix in repo kogen, all six locations (02-shaping.feature:22,:379,:380,:395,:423 and 06-reviewing.feature:33) are exercised by acceptance.feature using the existing installed-release harness. The Outline retains both scripts and exact diagnostic lines 12 and 14.
- Addressed: local declared rejection cannot be waived; undefined bindings remain errors after assertion failures; questions preserve prior files; scratch probe isolation/recording/cleanup; complete initial review evidence delivery before approval. See acceptance.feature and Tests.
- Addressed: request evidence sequence uses the packaged release and all cases three times followed by npm test (8 workers, not @live), with no retries or exclusions beyond the existing non-live filter.
- Historical context retained, not a new expected total: main b7206f9 on MacBook, 1 Nov 2026, 266 scenarios, 251 passed, 15 failed, 176 seconds; unrelated Build ed2d49f5 observed those same failures six times. Only chapter 04 was configured. Current checkout may have different totals. Compare actual per-scenario results, not only aggregate counts. The request mentions full failure output but supplies only the summarized symptoms; do not invent missing transcripts.
- Omitted deliberately: repairs to the other failures, new commands/options, timeout/retry/limit changes, and expansion of configured checks. No conflicting or superseded requested behavior.

## Tests
- Declared local rejection is not waived by unchanged acknowledgment: unchanged spec/features/02-shaping.feature:22 (regression)
- Undefined bindings are reported even after an assertion failure: unchanged Outline rows :379 and :380, including exact diagnostics and refusal of approval (regression)
- A question after not-ready preserves attempted files and leaves approval absent: unchanged :395 (regression)
- Feasibility probe executes outside project, records result and removes scratch without project mutation: unchanged :423 (regression)
- Oversized initial source reaches independent review completely before approval: unchanged spec/features/06-reviewing.feature:33 (regression)
- Existing passing non-live scenarios do not regress: compare complete suite per-scenario outcomes to a retained baseline, and report totals (existing)

Implementation investigation should include cli/shape/shape.go and readiness handling in cli/verify, probe recording and scratch handling, and review source delivery in cli/build. Existing test/acceptance/support/handlers.js inspects these effects and fake-servers.js supplies the scripts. Do not equate clipped read output with complete delivery or change an expectation merely to accept it. Add focused Go regression coverage for any corrected logic that existing scenario coverage does not isolate.

For delivery, package with sh packaging/package.sh and pin that archive with KOGEN_ARCHIVE for all evidence runs. From test/acceptance run npx cucumber-js --parallel 8 --strict --tags "not @live" --require "steps/*.js" --require "support/*.js" ../../spec/features/02-shaping.feature:22:379:380:395:423 ../../spec/features/06-reviewing.feature:33 three times, each reporting exactly six passed cases. Then run npm test once against the same archive, retain per-scenario output and report totals. Retain an unfixed full-suite baseline for the no-regression comparison; unrelated existing failures need not become green but no formerly passing case may fail. These are verification repetitions explicitly requested, not automatic failure retries. Native Intent acceptance reuses the real suite harness through a registration-only bridge; production changes and the existing harness remain outside Acceptance so the builder can make warranted implementation repairs.

## Feasibility
- none
