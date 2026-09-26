# Requested focused diagnostics — 2026-09-22

## Scope and observed result

The Shaper explicitly requested appropriate tests in parallel and corrections to
the Intent based on failures. Source baseline is main at
`c1f085324f78d5030c8d3d7b6efc2df248ff01c2`, with the existing dirty failed
implementation (31 modified tracked files and four untracked implementation/test
files). No source, maintained test, configuration, or hook was repaired here.
The experiments execute that current implementation, not the future amendments.

234 existing offline tests passed across 41 files. The standalone live
reviewer-rework owner failed before provider dispatch. A source-bound workspace
probe accepted regular seeds but incorrectly rejected a valid contained relative
Mix link; its runtime-targeting negative control was correctly rejected.

This is diagnostic evidence, not a Stop Verification Record, complete-suite
settlement, proof of all seven scenarios, or a guarantee of the next Build.
The current dirty checkout also does not satisfy clean-control Build admission;
no user changes were discarded or transferred during these diagnostics.

## Parallel execution and exact commands

Each batch used one Mix invocation so compilation completed before its tests,
with up to four async cases concurrently. Existing isolated-case machinery
created private child VMs and owned fixture roots for cwd/environment-mutating
tests. The batches themselves were sequential: no two Mix compilers shared the
outer build tree. The test/support PATH shim denied default provider resolution;
these files used their maintained fake/isolated harness routes. This is not a
claim that a PATH shim alone intercepts every absolute native launcher.

Batch A: all 23 then-current unique scenario `proof.offline` files; exit 0,
127 passed, ExUnit seed 998712, 42.8 seconds reported by ExUnit:

```sh
PATH="$PWD/test/support:$PATH" mix test --exclude live --max-cases 4 test/kogen/build_workspace_test.exs test/kogen/harness_role_test.exs test/kogen/codex_environment_test.exs test/kogen/workspace_dependency_test.exs test/kogen/lifecycle_test.exs test/kogen/cold_offline_contract_test.exs test/kogen/offline_stage_results_test.exs test/kogen/isolation_test.exs test/kogen/selective_verification_targets_test.exs test/kogen/failure_signature_test.exs test/kogen/scenario_tracking_test.exs test/kogen/test_reliability_catalog_test.exs test/kogen/whole_suite_remediation_test.exs test/kogen/verification_ownership_lifecycle_test.exs test/kogen/live_rework_audit_test.exs test/kogen/two_outer_resumptions_test.exs test/kogen/unified_state_admission_test.exs test/kogen/reviewer_mutation_test.exs test/kogen/worktree_publication_recovery_test.exs test/kogen/commit_failure_rollback_test.exs test/kogen/build_preconditions_test.exs test/kogen/core_integrity_test.exs test/kogen/isolation_cleanup_test.exs
```

Batch B: the other 17 affected offline test files; exit 0, 103 passed,
seed 204173, 84.5 seconds:

```sh
PATH="$PWD/test/support:$PATH" mix test --exclude live --max-cases 4 test/kogen/configuration_support_contract_test.exs test/kogen/codex_compatibility_preparation_test.exs test/kogen/live_native_receipt_audit_test.exs test/kogen/provider_outcome_test.exs test/kogen/stop_hook_test.exs test/kogen/check_test.exs test/kogen/check_settlement_test.exs test/kogen/developer_handoff_test.exs test/kogen/guarded_paths_test.exs test/kogen/target_evidence_test.exs test/kogen/settlement_regression_test.exs test/kogen/scenario_lifecycle_test.exs test/kogen/commit_provenance_test.exs test/kogen/codex_public_tasks_test.exs test/kogen/git_integrity_test.exs test/kogen/git_test.exs test/kogen/approved_mutation_test.exs
```

Additional existing live-native consumer's offline assertions; exit 0,
4 passed and the one live case excluded, seed 39230, 1.9 seconds:

```sh
PATH="$PWD/test/support:$PATH" mix test --exclude live --max-cases 4 test/kogen/codex_compatibility_test.exs
```

These times are individual test-run durations, not complete-task cost or a future
Build ETA. Root also inspected source, authored Draft changes and ran probes;
Luna-low and Sol-medium helpers performed read-only discovery/audit. Exact
combined token/cost usage was unavailable; missing usage is not zero.

## Standalone live-owner failure

```sh
mix test --only live test/kogen/live_reviewer_rework_test.exs
```

Exit 2, 0/1 passed, seed 663852, 3.9 seconds. Observed failure:

```text
UndefinedFunctionError: Kogen.CompiledFixture.prepare_build!/2 is undefined
(module Kogen.CompiledFixture is not available)
test/support/live_reviewer_rework_fixture.ex:63
test/kogen/live_reviewer_rework_test.exs:19
```

The actual owner loaded its own require chain, prepared and compiled its private
fixture, then failed at the missing helper call before its Build/provider launch.
Retained setup output:
`.kogen/runtime/live-evidence/reviewer-rework-74313-5/fixture-precompile.log`
and `fixture-path.txt`. The test removed its owned fixture
`.kogen/runtime/live-reviewer-rework/fixture-74313-69`; absence was checked.
No private raw Codex logs were copied into this package.

The source explains why aggregate green tests miss this: `lifecycle_test.exs:1`
requires CompiledFixture in its VM, while the standalone live owner's own chain
does not. Loading both in one VM can conceal the missing import. The revised
contract therefore requires an independent fresh child for each live owner, not
an aggregate loading check.

## Source-linked admission probe and controls

Maintained diagnostic script: `seed-admission-probe.exs` in this evidence folder.

```sh
elixir -pa '_build/test/lib/*/ebin' .kogen/intents/drafts/isolated-candidate-workspace/evidence/seed-admission-probe.exs
```

Exit 0 means the diagnostic completed, not that the proposed behavior passed.
It invoked compiled production `Kogen.Build.Workspace.open/4` against three
owned disposable Git repositories with otherwise identical minimal seed inputs:

| Input | Observation | Contract consequence |
| --- | --- | --- |
| Regular synthetic seed files | Accepted; retirement returned ok | Valid admission control |
| `_build/dev/lib/kogen/priv -> ../../../../priv`, target tracked and present | Rejected as unsafe warm seed symlink | Fails the corrected contained-Mix-link requirement |
| Same link location targeting existing `.kogen/runtime/unsafe` | Rejected as unsafe warm seed symlink | Correct unsafe-link refusal |

For all three, source contents were unchanged, only the original worktree
remained, and no Candidate branches remained after retirement/refusal. The
script removed only its own temporary repositories and reported their absence.
These minimal seeds do not establish real Mix incremental compilation, genuine
compiled-artifact validity, or the full live fixture route. Those remain required
maintained controls; the probe must not substitute for them.

## Contract repairs resulting from the diagnostics

- Replace the obsolete `rejects every warm-seed symlink` assertion in
  `build_workspace_test.exs` with positive contained-link and negative unsafe-link
  controls. The old assertion being green proves the wrong behavior.
- Give each selected live owner a standalone fresh-process prerequisite test,
  sharing its real setup entrypoint with paid execution and denying actual
  dispatch. No externally preloaded helper, duplicated setup, or audit-helper-only
  success may count. Missing helpers/tool-selection files/seeds must fail locally.
- For the connected owner, distinguish pre-Shape test-only fixture/seed admission
  from validation of the actual shaped package after it exists. The former cannot
  prove the latter or replace the required connected live route.
- Replace the synthetic-only dependency-environment test with real clone and
  incremental reuse/invalidation controls, as the existing contract already
  requires. Do not dereference all links in fixture copying to hide the defect.
- Make the hook-free publication positive control require success, not allow
  either success or a commit failure. Register all changed/new test declarations
  in the maintained reliability catalog.
- `developer-testing.md` now explicitly requires focused iteration during edits,
  separate from the prescribed two readiness bundle executions and Stop gates.
  This is an instruction, not a claim that the future Developer already ran it.

## Unexecuted boundaries and preservation

No full Make gate, cold recipe, native/provider compatibility campaign, or
connected Shape-to-Build rerun was performed in this diagnostic batch. The
previous source-linked connected failure remains retained in
`paid-verification-reconciliation.md`; no evidence here claims it has been fixed.
The prior native/cold successes are not overwritten with fresh unsupported claims.
Known deterministic setup failures must be corrected and locally exercised before
spending on those real selected routes. Full independent verification still has
to pass after implementation.

Existing host `_build/lib/kogen/priv` points into an old runtime worktree and is
not admitted by the corrected link policy. It was not deleted or legitimized to
make these diagnostics green. Clean control and valid source seeds remain
installation prerequisites; normal Build must fail closed on unsafe inputs.

## Source binding

`python3 -B scripts/check/offline.py --source-manifest-sha256` after the tests:

```text
4be4e1c98456230c4dd56eb7128341a1a399a5e3f1de0b3358db94bbc45ab7b4
```

Selected actual source SHA-256 values from `shasum -a 256`:

```text
31b4f8cdc20fcfb741d7ec6b2eebaf83890b68e57533125a582af4629ddb9039  lib/kogen/build/workspace.ex
f85cfc980263b95d7249578015ad06fdac174c42df7166b6592b07dd1986ae9d  test/kogen/build_workspace_test.exs
4df6b4f72ad30a15587eabcd68d6461b2eba6d58e456e04da8ca0e10e72545c9  test/kogen/workspace_dependency_test.exs
0055abb690b14bd0d5e60406714ea975184bb92816fea45d781d017a6c935217  test/kogen/live_reviewer_rework_test.exs
f7aba044165e9337a2dffc5c4ea4ebcf1ced97c199f9908fc92b479ba28cc1c7  test/support/live_reviewer_rework_fixture.ex
4c92fbdf81cf61a533acc605a7c428fd73f2e3b13cc0d362e9932016df9d2594  test/support/compiled_fixture.exs
1bd2b72f9b4bd923831916945123e991fce5f432145ffdc7b78cd6bd6ab906b0  test/kogen/live_rework_audit_test.exs
1e374ca25026618b958619539399085612e703ca6e6610ff2810b2d4760a3a63  test/kogen/lifecycle_test.exs
a6232229ad2dab000b631da4916f4e18818b0b0b94291e3a8348867b8e5447a8  test/kogen/commit_failure_rollback_test.exs
```

