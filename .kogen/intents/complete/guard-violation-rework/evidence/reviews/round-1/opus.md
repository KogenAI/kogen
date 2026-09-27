## Findings

- **[BLOCKING] Making the Approved copy read-only breaks every Build.** `package_entries` records `stat.mode` (`lib/kogen/build.ex:190-204`), and `approved_unchanged` compares the Candidate copy's modes to control's frozen modes (`build.ex:219-227`). That check already runs before the first launch (`build.ex:632` → `:1581`), so a 0444/0555 copy stops every Build with "Approved Intent changed during Build". Deletion also fails with EACCES in more places than "Candidate removal": publication's `File.rm_rf!(approved_dir)` (`build.ex:1953`), the restore (`build.ex:2049-2050`, which raises again inside the rescue), `remove_published` (`lib/kogen/build/workspace.ex:594`) and `delete` (`workspace.ex:834`). — Fix: name all of these sites. Compare the Candidate copy against the expected read-only modes. Add one Workspace helper that restores write permission and use it at every deletion site.

- **[BLOCKING] Existing tests outside `may_change_guarded_paths` will fail.**
  - `test/kogen/approved_mutation_test.exs:219,224-234`: 9 cases write into the Candidate copy and assert the write happened.
  - `test/kogen/build_workspace_test.exs:671-672`: expects `stopped: integrity`, but on any other resume `fake_codex` rewrites `dummy.txt` and adds `reviewer-rework-marker.txt` (`test/support/fake_codex:102-105`), so the Build now ends as guard-violation.
  - `test/kogen/core_integrity_test.exs:202-215`: asserts `integrity`, but on resume the fake's `ln -s` (`:364`) fails under `set -e`.
  - Fix: add these three files to `may_change_guarded_paths` and state their new expected outcomes.

- **[BLOCKING] The shared budget can't be built inside the guarded paths.** `verification_retries` is counted in Verification's own persisted state, which checks itself (`lib/kogen/build/verification.ex:208-233,713-734`), and settle requires `passed` or `exhausted` (`:532`). Sharing the budget means editing `verification.ex`, which is not guarded, so the old controller would stop this Build. Separately, after build-reliability lands, `verification_retries` becomes the paid budget and `offline_retries` covers Candidate-caused failures (`plan/briefs/build-reliability.md:33-36`). — Fix: keep a separate counter in `build.ex` (entries in `guard_violations` ≤ the budget). Decide now that the budget is `offline_retries`, instead of the conditional in `intent.yaml:11-12` / `risks.yaml:12-15`. Reword stray-file-reworked's "one unit spent". Say whether the "retries left" line in the prompt (`build.ex:832-863`) includes guard violations.

- **[BLOCKING] The terminal ("protected") set misses where hooks are registered.** `.codex/hooks.json` and `.codex/config.toml` sit outside `.codex/hooks/**`. Claude also loads the Candidate's own `.claude/settings*.json` (`lib/kogen/harness/claude.ex:162-163`, `--setting-sources project`). If an unguarded edit there is reworked, the Developer's own hook runs in the resumed turn. That is the reason the draft keeps hook edits terminal. — Fix: protect `.codex/hooks/**`, `.codex/hooks.json`, `.codex/config.toml` and `.claude/**`, and add a case to terminal-guard-failures-stay-terminal.

- **[ADVISORY] Distinct categories conflict with identical messages.** `stop_category` matches on the message prefix (`build.ex:1661-1679`, via `retained/2` at `:1654-1658`). Protected-path, guard-violation and harness-failure-plus-guard stops all start with "Candidate changed paths outside Approved guards". — Fix: pass the category explicitly through `stop/3`, and say which category the core_integrity case gets.

- **[ADVISORY] The Python half of approved-copy-read-only proves nothing.** CPython silently skips a `__pycache__` it can't write, so there is no EACCES to record. `__pycache__` is already ignored by the guard (`lib/kogen/build/guarded_paths.ex:179`). If launchers adopt `PYTHONDONTWRITEBYTECODE` (lesson 21's rule), the check becomes empty. — Fix: assert the 0444/0555 modes, that no `__pycache__` exists, EACCES on `extra.txt`, and that the Build is accepted.

- **[ADVISORY] A real Developer differs from the fake.** "Remove or revert them" invites `git clean -fdx`, `git stash -u` or `git checkout .`. Those delete the ignored `deps/` and Approved copy (which then stops the Build) or revert guarded work. Stray files written by a controller verification cycle would also be blamed on the Developer. — Fix: the prompt should say to delete or restore exactly the listed paths, with no git clean/stash/reset and no TMPDIR override.

- **[ADVISORY] Test isolation.** The new test must `use Kogen.IsolatedCase, async: true` (`test/kogen/isolation_test.exs:169-175`), because `Fixture.build!` changes global env and cwd (`test/support/workspace_fixture.ex:227-240`). Retained Candidates with 0555 directories will survive the suites' `on_exit` `File.rm_rf`.

- **[ADVISORY] Package gaps.** `references.yaml` omits lesson 21. There is no `evidence/` directory. It's unspecified whether the occurrence that exhausts the budget gets a `guard_violations` entry (2 or 3 in stray-file-budget-spent).

D1, rules 36, 37 and 44, and §1.16: no violations found. Nothing auto-approves or notifies, and the tagged returns have a caller.

## Verdict: not ready
