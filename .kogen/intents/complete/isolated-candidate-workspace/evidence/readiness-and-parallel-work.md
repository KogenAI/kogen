# Readiness, timing, and parallel-work gap — 2026-09-22

The Shaper asked whether the next Build could be guaranteed to finish, whether it would be fast, and explained that worktrees are urgently needed for parallel work. Read-only inspection found the following limits. No Build, verification target, or source repair was run for this assessment.

## Outcome gap

`lib/kogen/build.ex` uses one `.kogen/build.lock`, acquired before `do_build/3` and released after it returns; a second invocation from the same control checkout fails. The Draft retains that ownership model. `lib/kogen/build/guarded_paths.ex` in the failed implementation compares all refs and worktree registrations, so sibling commits or registration changes can also stop a running Build. The Draft's publication contract requires main to equal its admitted starting ref. Separate Candidate directories alone do not supply concurrent development/publication semantics.

Whether the user requires concurrent Kogen Builds or other coding sessions alongside one Build is now an open shaping question. There is no silently accepted publication queue, automatic rebase, stale-Candidate acceptance, or conflict-resolution policy.

## Remaining deterministic prerequisites

- The current dirty failed implementation still rejects all seed symlinks in `Workspace.walk/2`; the amended safe-relative-link policy has not been implemented and passed.
- `_build/dev/lib/kogen/priv` and `_build/test/lib/kogen/priv` currently point to `../../../../priv`. However, `_build/lib/kogen/priv` points to `../../../.kogen/runtime/build-worktrees/checkouts/01a0b404-3838-7365-93f4-a49d5cf201cd-yfZLhGotyo7jwAAX7ONGVxpfAbcnKQoV/priv`. It remains invalid under the amended policy. No runtime tree or cache was deleted, rewritten, or adopted during this assessment.
- `test/support/live_reviewer_rework_fixture.ex` still calls script-backed `Kogen.CompiledFixture.prepare_build!/2` without loading it through the live owner's require chain. Fixture preparation also dereferences links with `cp -cRL`, which cannot demonstrate the promised production symlink-preserving route.
- `test/kogen/workspace_dependency_test.exs` currently checks a synthetic environment map. It does not establish real incremental reuse, stale-artifact invalidation, or clone failure behavior.
- `test/kogen/commit_failure_rollback_test.exs` currently permits either success or a commit failure in its hook-free-publication success case. The Draft now explicitly rejects that ambiguous positive control.
- The installed Developer prompt says readiness commands run only at two points, and the Draft excludes role-prompt changes. A Draft instruction to iterate cannot by itself prove that the installing Developer follows a conflicting fixed-point launch prompt. No extra attestation or trust in Developer claims is proposed.

These facts prevent a next-run guarantee. Package parsing establishes syntax and admission structure only. Corrected focused controls and actual lifecycle success are still needed.

## Timing evidence

Source: `.kogen/runtime/scenario-tracking/Zi1QBLqbAFvZqdOkAyhrAjdk/record.json`, each attempt's verification cycles and target output. Rounded ranges from the three observed cycles:

| Target | Observed duration | Result |
| --- | --- | --- |
| check | 116–140 seconds | Passed all three |
| cold-offline | 128–149 seconds | Passed all three |
| live-native | 331–403 seconds | Passed twice, failed once |
| live-reviewer-rework | 4–5 seconds | Failed during setup in both reached cycles |
| live-shape-to-build | Not reached by this Build | Separate diagnostic failed after about 254 seconds |

The first three targets alone used about 9.6–11.4 minutes per cycle. Across all three cycles, recorded target execution totaled about 32 minutes, excluding Developer work, surrounding controller time, and the separate diagnostic run. A successful full lifecycle has not been measured for this Candidate; these durations are neither an ETA nor an upper bound.

The existing Stop runner executes targets sequentially and starts from check on each new cycle. The Draft preserves that authority and retry policy. APFS cloning and incremental compilation may reduce workspace startup work, but the earlier clone probe explicitly retained no valid timing measurement. There is no established startup latency bound or evidence that this full installing Build will be fast.

## Later scope and instruction reconciliation — 2026-09-22

The observations above are retained as historical findings. The Shaper subsequently
selected basic single-Build isolation first and parked concurrency, stopped-Build
continuation, and newer-main integration in separate briefs. The parallel-work
gap is therefore a future feature boundary, not a missing requirement in this
first Intent. Same-command continuation is accepted for that future shaping;
eligibility and repair authority remain open there.

Re-reading the installed Developer prompt resolves the apparent test-loop
conflict: lines 58–60 and 71–75 allow focused non-gate tests throughout
development, while lines 78–102 restrict the controller readiness bundle to two
points. `developer-testing.md` now requires individual focused iterations without
repeating that bundle or taking over Stop gates. This resolves the instruction
distinction, not the known implementation failures. No tests were rerun or source
repaired for this scope reconciliation; subsequent requested diagnostic runs
are separate evidence and do not establish a future success guarantee.
