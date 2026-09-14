# Diagnostic handoff for the next Build

Added at the Shaper's explicit request on 2026-09-14. This is historical failure context, not a change to approved requirements, a passing receipt, renewed allowance, or authorization to resume the old Build.

## Start here

The last Build was `7-LqmCEBuidKxHdDcTKG9gWw`. Its authoritative record is `.kogen/runtime/scenario-tracking/7-LqmCEBuidKxHdDcTKG9gWw/record.json`. [Selected retained attempt fields](attempts.json) include its digest and exact failure/target output. All three attempts passed check and failed live. No outer independent Review was reached. The running legacy controller exhausted its two outer resumptions; these historical charges do not prove the candidate's unified counters wrong.

The final stopped Candidate was `8e398359ef291eba6e7c88545138da4dac68570f`; Developer session was `01a0a020-dc07-7872-946c-cf64146be8da`. These identify historical evidence, not the new Build's active token/session or a restart checkpoint. Inspect the actual starting Candidate; do not assume it still equals that snapshot. Reuse available implementation and diagnose it rather than recreating the feature from scratch. Ordinary repairs remain allowed.

## Failures and observed progress

- Attempt 0: shaping evaluation's stateful-flawed prerequisite tried to read missing `evidence/calendar_adapter.py`. Shape-to-Build also failed its expected failed-then-passed Stop-history assertion.
- Attempt 1: the stateful-complete/stateful-flawed shaping cases exceeded the parallel suite deadline. The other five live cases passed.
- Attempt 2: shaping evaluation and Shape-to-Build passed, along with the other cases except native-helper. The native-helper assertion at `test/kogen/native_helper_live_test.exs:51` rejected `NativeHelperFixture.validate_receipt(receipt, protocol)` with `native receipt has missing or contradictory parent evidence`. Result: 5/6 passed. Earlier failures were no longer observed in this attempt; this does not establish permanent repair or waive fresh gates.

## Remaining investigation

Start with `test/support/native_helper_fixture.ex`, especially `collect_receipt!/5` and `validate_receipt/2`, and the live fixture's retained protocol, native receipt and raw parent/child snapshots. The validator collapses fixture-preservation, parent-profile, source-digest and child-validation failures into one message: the error text alone does not establish which check failed. Resolve the actual failing predicate before proposing a fix; do not weaken receipt validation or substitute model claims. Trace the log-directory producer in the live test to locate the run-specific artifacts. If exact receipts cannot be recovered, report that evidence limit and use a focused deterministic reproduction with valid/disconfirming controls; do not assert a root cause from the aggregate error.

Cloudflare OAuth warnings and patch-tool errors were present, but no inspected evidence establishes them as the native-helper failure's cause. The prior missing-settlement controller/hook mismatch was not the recorded stop reason in this run.

The Developer must preserve machinery-owned gate execution. Focused non-gate diagnosis/tests remain permitted; do not manually run check/live or the Stop script. A new Build still needs fresh required verification and independent Review for all scenarios. Historical successful cases are diagnostic context only. This handoff makes no promise that a blind rerun will pass.
