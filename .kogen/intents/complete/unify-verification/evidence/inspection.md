> Historical shaping inspection notes. References below to provisional policy or future choices describe the time of inspection; the current contract and decision disposition are maintained in the package root.

# Source inspection — 2026-09-14

Read root README.md, .kogen/config.yaml, Makefile, initiating follow-up, lib/kogen/build.ex settlement through rework, config normalization in lib/kogen/intent.ex, and tracking ownership in lib/kogen/build/tracking.ex.

`git status --short` returned no entries; `git rev-parse HEAD` returned the shaped-against HEAD. The follow-up's dirty-working-tree statement is historical. Current Build has no provider recovery implementation.

Build begin_attempt/4 records global attempt number and fresh token. settle/4, validate_handoff/6, run_declared_targets/5 and receive_review/5 all send quality failures to rework/4. rework compares attempt number against config.outer_resumptions. Passing Check or a target does not reset it. The empty target-list clause calls Review. Config requires outer_resumptions; Makefile declares check and live. Tracking owns exact bytes and never reloads its record as restart state.

observed-record.json retains a source-bound compact extraction with the original record SHA-256. No source mutation, gate execution, paid invocation or behavioral probe was performed. The existing observed failure establishes the problem; it does not demonstrate the proposed implementation.

## Bounded scout coverage

Native explorer budget_tests ran configured gpt-5.6-luna at low, read-only. Reported relevant coverage: test/kogen/scenario_lifecycle_test.exs:53-125 (target exhaustion, regression, separate records); test/kogen/lifecycle_test.exs:123-186 (same Developer, fresh Review, two-resumption receipt); test/kogen/verification_ownership_lifecycle_test.exs:8-85 (ordered target reruns); test/support/scenario_lifecycle_harness.py:109-180 (deterministic modes); test/kogen/scenario_tracking_test.exs:100-179 (finding history); test/kogen/reviewer_mutation_test.exs:114-125 (integrity stop).

Scout found no existing combined two-target-failures/first-Review-repair success case or explicit budget transition, partial-progress, and alternating-failure bounds. These are implementation coverage requirements once the Shaper chooses policy. Root independently inspected the consequential shared-counter and clean-baseline facts. No helper executed tests or wrote files.

## Unified-hook investigation

Read actual check.sh, hooks.json, Check, VerificationPolicy, Harness launch/parse paths, TargetEvidence capture/verify, verification ownership fixture, live target envelopes and check workflow. Bounded read-only scout follow-up confirmed no existing native failure-threshold mechanism. Root's native probe resolves that uncertainty; see native-stop-findings.md.

Current Stop timeout is 600 seconds; live_shaping_evaluation_test.exs permits 5700 seconds and other live lifecycle modules permit 900. Hook-owned live must preserve those envelopes and settle children on failure, not inherit the short offline-only timeout.

KOGEN_VERIFICATION_TARGETS is the prohibited-command set, always including live; it is NOT the list to execute. New execution context must carry check plus deduplicated declared scenario targets, without running undeclared live. Current Build runs compiled old controller code while its Developer changes the tracked hook, requiring explicit legacy-controller compatibility during this self-build.

TargetEvidence.capture consumes full target output and snapshots manifest/artifact bytes immediately. Moving it after a Stop continuation would let the Developer remove or change ephemeral evidence first; capture must stay at target completion inside the machine-owned hook path. Build later imports and validates owned receipts, and Review consumes retained snapshots.
