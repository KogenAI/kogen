# Audit of the `isolated-candidate-workspace` Draft

**Verdict: not ready for approval.** The goal, appetite, non-goals and the honest "structural, not security" statement are sound. Six blocking gaps remain. The publication/crash-recovery and Git common-directory ownership gaps change the design; the rest are contract or guard fixes. I edited nothing, ran no paid targets, and ran no Mix commands. Everything below comes from reading source, Git metadata and the Draft at `7c7c3426`. Findings are tagged **[obs]** for observed facts and **[inf]** for inference.

## Blocking findings

**B1. The publication design leaves out the control checkout, the Approved package and any recovery record**

- `main` is checked out in control, so raw `update-ref` moves HEAD without updating its index/files; the probe did not check control status.
- Approved is ignored and absent from a HEAD-created Candidate. The Draft did not define its Candidate copy, Complete construction, control cleanup, durable recovery journal, or pre/post-main crash policy.
- A post-main crash could leave the lock, Approved/Complete, and control synchronization unsettled.

**B2. Verification ownership is split and required files are unguarded**

- Candidate-root `stop_runner.py` requires context `project_root` to match Candidate.
- `Verification.initialize` derived project root from control tracking and wrote absolute state/history there; `Kogen.Check` used cwd-relative control files.
- Required paths included `lib/kogen/check.ex`, `.codex/hooks/stop_runner.py`, and Stop tests.

**B3. Shared Git common state had no owner**

- Roles bypass sandbox; linked worktrees share config, hooks, excludes, refs, stash, and registration.
- Current `git commit` runs hooks. `GuardedPaths` assumes `.git` is a directory.
- Role limits must be described as detected/refused, with shared-state snapshots, hook-free publication, and malicious controls.

**B4. Guarded paths omitted proof consumers**

- Missing paths included Stop/check, live rework audit, lifecycle/settlement/provenance/public-task consumers, scenario harness, and live-native rehearsal parity files/catalog.

**B5. Candidate parent and authorized cold seeds were undefined**

- Collision/canonical trust depends on a fixed owned parent.
- The successful probe copied user Hex/Mix caches, but the Draft did not name authorized seeds or preservation hashes.
- Current cold-offline copies installed deps and empties only `_build`; the reason overstated first-cold behavior unless rewritten.

**B6. One offline selector ran zero tests**

- `test/kogen/cold_offline_test.exs` is tagged `:live` and excluded by default; it cannot serve as an ordinary offline selector.

## Nonblocking improvements

- Preserve only the observed historical negative control (accepted result absent from main), not an unproven mechanism.
- Protect existing foreign worktrees/refs; forbid global prune and hash topology before/after.
- Remove silent cwd defaults or rehearse from a sentinel cwd.
- State that Candidate-authored Stop/check code remains, with immutable controller-generation binding deferred.
- Account for macOS `/var` canonicalization/socket path lengths.
- Specify successful versus failed cleanup lifecycle without adding a command.
- Do not claim `live-shape-to-build` proves dependency/cache preservation; its fixture is trivial.
- Add ownership fields to the structural-not-security risk.
- Scope is near the appetite limit.

## What holds up

- Self-hosting has no circularity: the installing Build runs the admitted controller and tests the future route.
- The pinned-runtime negative control is sound.
- Proof maps have the required target shape.
- No compatibility/fallback path was proposed beyond cwd defaults.
- Historical receipts were not treated as current proof.

This retained file preserves the audit's complete findings and distinctions; terminal-only connector boilerplate was unrelated to the repository audit and is omitted.
