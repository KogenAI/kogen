# Focused tests during implementation

This is a required Developer working instruction for this Intent, not a new
verification record or an alternative to independent verification.

First follow `developer-recovery.md`: continue the exact retained 41-file implementation,
then use the loop below to repair it. Restoring existing work is not a test pass.
`repair-plan.md` supplies the required current repair order and exact controls;
add those assertions before relying on these previously green selectors.
The complete Candidate relative to `c1f08532`, including all imported files, must
pass verification and independent Review, not merely the subsequent repair diff.

## Working loop

The latest failed Build ran focused tests, but their old fixtures omitted the
new behavior. Before treating any listed selector as useful feedback, add the
regression that demonstrates its observed defect: real producer output into the
real consumer, then its disconfirming input. See repair-plan section 2 for the
complete live-audit migration and latest-build reconciliation for source locators.
This is required behavior, not a registry of test names or a handoff attestation.

1. Follow the controller-issued readiness commands at their prescribed beginning
   and final points. Do not repeatedly run that full command bundle.
2. Use each affected scenario's `proof.offline` selectors to choose focused
   non-gate tests while editing. Run the relevant tests after each repair, inspect
   failures, and repeat within the existing allowances. Do not defer a known
   deterministic failure to paid verification.
3. Run live-owner setup controls in fresh provider-denied child processes before
   relying on the paid route. Those controls must exercise actual fixture
   loading, warm seeds, tool selection, and workspace admission, not just mocks.
4. Finish with the prescribed readiness command. Stop then independently runs
   `check` and this Intent's selected declared targets. Exhaustion still stops the
   role; this instruction does not authorize unlimited repair.

The installed prompt explicitly permits focused non-gate tests throughout
development. Its two-point rule is for the controller-issued readiness bundle.
Do not invoke Make gates, Stop, or live providers yourself or through helpers.
No extra handoff attestation is required, and Developer claims are not trusted
as gate receipts.

## First repairs to exercise locally

Run these as focused commands in the implementation project root after the
corresponding changes; each invocation has its own test process:

```sh
mix test --exclude live test/kogen/live_rework_audit_test.exs
mix test --exclude live test/kogen/lifecycle_test.exs
mix test --exclude live test/kogen/build_workspace_test.exs test/kogen/workspace_dependency_test.exs
mix test --exclude live test/kogen/commit_failure_rollback_test.exs test/kogen/worktree_publication_recovery_test.exs
mix test --exclude live test/kogen/scenario_tracking_test.exs test/kogen/scenario_lifecycle_test.exs test/kogen/developer_handoff_test.exs test/kogen/reviewer_mutation_test.exs
mix test --exclude live test/kogen/test_reliability_catalog_test.exs test/kogen/whole_suite_remediation_test.exs test/kogen/cold_offline_contract_test.exs
mix test --exclude live test/kogen/terminal_probe_test.exs
```

The first two files must be extended as specified by the scenarios: load the
real standalone live owners and their own dependency chains in fresh children,
prepare their real fixtures, and reach the dispatch boundary without a provider
call. An existing green audit-helper test alone is insufficient. Missing-helper
and unsafe-seed controls fail at their intended local boundaries; realistic
contained relative Mix links succeed without dereferencing into shared state.

Use one fresh OS/BEAM child per live owner. Do not put the lifecycle test and a
live owner, or both live owners, into the same prerequisite child: preloaded
modules can hide a missing require. The child loads only its owner's declared
dependencies; its correct counterpart must not receive an undeclared helper
from the test runner. The paid test and offline control call the same fixture
preparation entrypoint, not duplicated setup. Deny provider execution at the
actual selected dispatch boundary, not merely a PATH name the native launcher
might bypass, and assert zero attempts for all prerequisite controls.

For the connected owner, test fixture/seed readiness before paid Shape with
clearly test-only admission inputs; validate the real shaped contract only after
Shape produces it and before Developer dispatch. Do not claim the early local
check proves the unexecuted connected lifecycle. Missing `mix.lock`, `mise.toml`,
`deps/`, or `_build/` must fail locally rather than trigger provider work.

The workspace tests must prove actual clone isolation and normal incremental
reuse/invalidation, not merely compare environment strings. The publication
positive control must require success; accepting either success or failure is
not proof. An existing runtime-targeting seed link must be rejected, not admitted
to make a test pass. Do not delete or adopt unowned host artifacts to obtain green.

The current test named `rejects every warm-seed symlink` encodes superseded
behavior. Replace it with distinct valid-contained and invalid-link cases, not
another assertion that accepts the broken implementation. Register new/changed
declarations in the maintained reliability catalog. Today's passing selectors
are a baseline, not proof that these missing regression tests already exist.

## Remaining affected scenarios

`scenarios.yaml` is the maintained full test map, including routing, private
state, reliability receipts, same-Candidate rework, publication, failure cleanup,
and installing-authority preservation. Run the relevant `proof.offline` test
files with `mix test --exclude live <file> ...`; include unchanged consumers when
their behavior is affected. The commands above prioritize the observed failures
and are not a replacement for that map or the final readiness plan.

This installing Intent still selects `check`, `cold-offline`, `live-native`,
`live-reviewer-rework`, and `live-shape-to-build`. Their distinct required
observations have not been removed merely to make the next run shorter. Later
Intents select their own narrow affected boundaries; there is no blanket rule to
run all live targets.
