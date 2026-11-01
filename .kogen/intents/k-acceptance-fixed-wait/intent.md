# Remove acceptance liveness padding

Slug: k-acceptance-fixed-wait
Model: not applicable — this changes observation timing in an existing test harness, not a product state machine
Acceptance:
- .kogen/intents/k-acceptance-fixed-wait/acceptance.feature
- features/steps/k_acceptance_fixed_wait_steps.js

Fix the acceptance handler for `the kogen command is still running` in `test/acceptance/support/handlers.js`. Test-suite speed takes priority. Remove unconditional two-second padding when preceding observable progress already establishes the point at which to inspect liveness. Preserve process-state checks, OS liveness checks, negative controls, scenario assertions and cleanup. No new command, flag or option, and no timeout, retry or limit change.

## Decisions
- Scope is only this acceptance step; shape/refine sleep 1 / sleep 10 probes and the native interruption test's 300 ms pre-signal wait belong to K-CHECKTIME-CLOCK and remain untouched. (source: request)
- Measure only the three affected scenarios, three fresh uncached runs each before and after on the same host, with zero failures, plus configured checks. Do not fix unrelated baseline failures or claim or measure complete-suite speedup. (source: request)
- The affected scenarios are `Ordinary implementation failures keep repairing until the caller stops it` (04-building.feature), `A redirect with the wrong state is ignored and the right one succeeds` (08-chatgpt.feature), and `SIGINT sent to a command's process group cancels nothing; cancellation comes only from kogen` (09-cli-and-process.feature). Preserve them and their assertions. (source: request)

For the first scenario, feedback of verification pass 25 is the observable progress point. For the second, receipt of the wrong-state HTTP response is the observable progress point. Inspect process state there without fixed padding. For the process-group SIGINT scenario, sending a signal is not proof that cancellation was ignored: retain its two-second negative-observation interval, scoped and documented for that scenario rather than imposed on the other two. Retain the unchanged subsequent assertions on the command, stdout, cancellation, exit code and HEAD. Do not replace meaningful negative observation with an immediate snapshot.

Add a runnable regression entry point `test/acceptance/fixed-wait-regression.cjs`, invoked with the installed Node runtime and no arguments. It must exercise the real dispatch handler (not a source-string assertion or replacement implementation), fail nonzero on any failed assertion, and print `fixed-wait regression passed` only after all cases ran. It must establish that a live process at the two progress points is observed without a two-second delay, that an already-exited process fails, and that the signal-negative case retains its observation interval and rejects a process that exits during that interval. Use local fixtures and deterministic observation where possible, preserving OS liveness and cleanup. A timing upper bound used solely to distinguish the old two-second pad is test evidence, not a changed product timeout. Keep regression implementation outside the protected acceptance package so Build can repair it.

Write `docs/k-acceptance-fixed-wait.md` with reproducible exact commands, host/toolchain identity, baseline and candidate revisions/tree identities, raw-result locations, per-scenario durations and failures for all 18 executions, and the affected-only aggregate for each repetition. Use fresh scenario worlds and fresh processes, no readiness/check-result cache; reuse the same host and comparable conditions on both sides. Capture baseline before editing the handler, using the actual baseline source, not a simulated sleep. Include measured handler elapsed contributions as distinct from total scenario wall time. Count three uses; six seconds per one execution of all three is only the nominal old padding, not a measured total. Report actual before/after values without promising a numeric speedup; identify retained fixed wait and its negative-observation reason. Record failures honestly; delivery requires zero affected-scenario failures. Preserve raw outputs in a reproducible retained location and include enough command/output detail in the note for independent review. The regression entry point must also validate that this measurement note contains all three runs on each side for each of the three scenarios and reports zero failures; do not manufacture measurements. Long measurement work may run separately during Build, not inside the fast regression entry point.

## Source comparison
- Addressed: Studio issue f877f021-6796-4a21-8089-dbb72d3fe88b, 31 Oct follow-up, K-ACCEPTANCE-FIXED-WAIT fix and test-suite-speed priority: outcome, Decisions and regression entry point above.
- Addressed: static audit at 3e759e88 had no timing evidence; this contract requires real before/after affected-scenario measurements and distinguishes nominal padding from observations.
- Superseded: original complete acceptance-run measurement request by the 1 Nov 2026 measurement constraint after ed2d49f5 review_blocked. This contract requires three affected scenarios, three runs each per side, zero failures, plus configured checks; no complete-suite timing claim.
- Omitted intentionally: repairs to the separately filed 15/266 npm test baseline failures in chapters 01, 02, 06, 07, 09, 10, and K-CHECKTIME-CLOCK waits. They remain out of scope.
- Addressed: same scenarios/assertions, negative controls and cleanup, no new command/flag/option or timeout/retry/limit change: boundaries and retained signal-negative interval above. The regression entry point is a test file, not a user CLI command.

## Tests
- Progress-observable liveness no longer imposes two-second padding: real-handler regression for feedback pass 25 and wrong-state response (regression)
- Exited processes fail liveness, including exit during the retained signal-negative interval: real-handler local process regression and cleanup (integration)
- Same three scenarios and assertions pass in three fresh runs before and after with zero failures: affected-only measurements and recorded raw results (scenario)
- Measurement scope, count, elapsed contributions and retained-wait reason are recorded without complete-suite speedup claims: regression entry point validates the measurement note; independent review checks actual commands/results (integration)
- Existing configured checks remain unchanged and run normally: configured verification (existing)

## Feasibility
- none
