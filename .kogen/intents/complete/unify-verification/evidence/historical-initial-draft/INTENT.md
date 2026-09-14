# Preserve bounded rework allowance after verification progress

Current approval: unapproved; shaping in progress. See [questions](questions.md).

## Outcome and appetite

One Build should be able to repair the first valid Review finding after earlier verification failures consumed the initial repair allowance. Keep every repair bounded, preserve actual verification and independent Review, and make budget progression inspectable. Fit budget accounting, configuration, retained evidence, documentation, and affected lifecycle verification into one Developer conversation with the configured two outer resumptions under the existing runner.

The initiating follow-up supplies the outcome, not an accepted reset algorithm. The recommended policy in questions.md remains a proposal.

## Walkthrough and challenge

From a clean checkout and an Approved Intent, Build launches one Developer. Two attempts fail a declared target; a subsequent attempt passes matching Check, a valid handoff, and every declared target. The first independent Review finds a real defect. Under the proposed policy, Build can resume the same Developer, rerun all gates under fresh bindings, and obtain a fresh independent Review that proves the repair before publication.

A naive implementation could reset on each passing Check and permit endless alternating Review/target failures. Acceptance must exercise repeated and alternating failures, partial target success, and regressions; successful earlier stages must not repeatedly replenish allowance. Attempt numbers remain globally monotonic even if the selected policy grants a new allowance.

## Preserved behavior and non-goals

Keep Check ownership, complete ordered outer verification reruns, exact Developer continuity, fresh Reviewer after rework, Candidate/token bindings, finding closure evidence, protected-input checks, and all existing integrity/malformed-Review stop semantics. Historical attempts remain evidence, not restart checkpoints.

Exclude parser recovery, authentication, fixture-flakiness repair, scheduling, and stopped-Build continuation. Do not restart or rewrite the exhausted Build. Provider transport recovery belongs to a separate Intent and is absent from the inspected accepted source; this change must not implement its retry schedule. If that feature lands before this Build, reconcile its independent allowance without charging or refreshing quality budgets.

## Evidence ownership and verification

The deterministic public Build fixture must exercise the selected budget policy through the actual controller before paid execution. Its outer driver owns sequence, session identity, attempts, and ephemeral invocation observations, retaining assertions and receipts for independent Review. Review assesses retained evidence and source; it need not reconstruct discarded native interactions.

Use declared Make targets `check` and `live` for the affected Build/Review route. The later Developer may run focused non-gate rehearsal; Stop owns check and Build owns live. Shaping has not executed either gate or implemented the proposed policy. Scenarios remain provisional until questions are resolved.
