## Findings

All five round-5 blockers are fixed:
- **Bounded packet field.** The packet's `guard_violations` field has a size cap, a digest-bound locator, an omission item and a large-record case.
- **Guard before retry.** A failed turn is still guard-checked before any provider retry. The provider fixture now cleans up before it fails, and the fail-without-cleanup case is (f2).
- **Work-turn notes.** The notes of a turn that ended in a guard rework are kept and combined for Jev, the record and the packet.
- **Protected-path prefix.** A `protected-path` stop keeps today's message prefix, so `candidate_verification_test.exs:161-168` passes unedited.
- **README.** The README change is named.

**Citations.** I checked the cited lines against the checkout (3ab70dce) and they hold: `build_workspace_test.exs:607-639,672-673,760-773`, `core_integrity_test.exs:196-209`, `guarded_paths_test.exs:13-39,41-79,201-209,211-219`, `candidate_verification_test.exs:161-168`, `isolation_test.exs:169-175`, `review_packet_test.exs:15-17,30`, `review_packet.ex:20-36,174-207`, `README.md:458-462`, `git.ex:153,238`, `write_boundary.ex:241-248,290`, `workspace_fixture.ex:121-131`, and shaping-quality `scenarios.yaml:361-370`. I could not check them at 82ac4351: that needs git, which this read-only review excluded.

**Other checks, no problem found:**
- **Rework commands in real sessions.** The Bash guard hook (`.codex/hooks/verification_policy.py:147-161`) allows `git show … > path`, `chmod` and `rm`.
- **Stop hook in fakes.** The Developer's Stop hook does nothing under the new controller (`stop_runner.py:229-230`), so it can't turn `approved_mutation_test`'s check-phase addition into a Developer-turn addition. That test passes unedited.
- **Capacity-marker fake.** There is a precedent for it (`controller_verification_test.exs:1427`).
- **No outside caller.** `GuardedPaths.check/2` has no caller outside the guarded files; only its `@volatile` list is parsed elsewhere (`prepare_test.exs:68-71`), and that list is unchanged.
- **Direction rules.** Nothing conflicts with D1, rules 36/37/44, §1.16 or shaping-quality, whose `build.ex` change is only in publication.

- [ADVISORY] **stray-file-budget-spent (b) runs into a hidden second attempt.**
  - In the workspace fixture, `fake_codex`'s first Review always asks for rework (`test/support/fake_codex:67-71`).
  - The rework resume then writes an unguarded `reviewer-rework-marker.txt` (`fake_codex:116-119`). The fixture guards only `dummy.txt` (`workspace_fixture.ex:170`).
  - So attempt 2 gets its own guard rework and has `offline_failures` 0. "One `guard_violations` entry and `offline_failures` 1" (`scenarios.yaml:56-58`) is true only for attempt 0.
  - **Fix:** in (b), use `create!(guards: ["dummy.txt", "reviewer-rework-marker.txt"])`, as `build_workspace_test.exs:359` does, and say "attempt 0".

- [ADVISORY] **The (2b) mode check doesn't test anything.** `git ls-files -s README.md` reads the index, and a worktree `chmod` never changes the index, so it shows 100644 whether or not the restore ran (`scenarios.yaml:29-30`). The accepted Build still proves the restore, because the guard compares modes with `core.filemode=true` (`guarded_paths.ex:186`).
  - **Fix:** assert the worktree mode instead: `File.stat!` mode 0o644, or an empty `git diff --raw HEAD -- README.md`.

- [ADVISORY] **A rework could skip the other input checks.** `approved_unchanged/1` is the second step of `inputs_unchanged/1`'s `with` chain (`build.ex:1961-1970`). An implementation that returns early on a reworkable Approved-copy addition skips the checks after it: references, record versions, review packets, ledger and target evidence, and `GuardedPaths.check`. A turn that also tampered with one of those would then be reworked instead of stopped. No scenario covers that combination.
  - **Fix:** say that a reworkable result still runs every remaining check. Add one case: an Approved-copy addition plus a `.codex/hooks.json` edit stops as `protected-path`.

## Verdict: ready

The claude.ai Stripe connector needs authorizing in your claude.ai connector settings; this review didn't need it.
