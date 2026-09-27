## Findings

Round 1 status: the read-only Approved copy was dropped, and the budget now uses a separate counter in `build.ex`, so those two are resolved. The protected-path set and the existing-test coverage were only partly fixed, and several new issues came up.

- **[BLOCKING] Tagged errors break a test the Developer can't edit.** `test/kogen/guarded_paths_test.exs:30-31,70-71` expects `check/2` to return `{:error, binary}` (`reason =~`, `reason == "Git configuration…"`). The file is not in `may_change_guarded_paths` and is cataloged in the ledger. — Fix: guard it (and the ledger), or keep `check/2`'s return shape and add a separately called classifier.

- **[BLOCKING] Edited tests go stale in the test-reliability ledger.** `approved_mutation_test`, `core_integrity_test` and `guarded_paths_test` each have a `source_sha256` in `priv/kogen/test-reliability.yaml`. After an edit, `check` fails with "source binding is stale" (`test/support/test_reliability_catalog.ex:119`, run from `test_reliability_catalog_test.exs:18`). Shaping-quality's audit also blocks this Draft (`ledger-closure`/`tracker-refresh-unstated`, `approved/shaping-quality/scenarios.yaml:351-353`). — Fix: guard the ledger and name `python3 scripts/check/refresh_test_reliability_sources.py`.

- **[BLOCKING] stray-file-reworked can't pass as written.** `package_entries` records directories (`build.ex:195-201`), and the fixture package has no `evidence/` (`workspace_fixture.ex:188-191`). `GuardedPaths` drops anything under `__pycache__` (`guarded_paths.ex:179`), so the path list has to come from the Approved-copy diff. If the prompt lists only `probe.pyc` and the fake deletes only that file, `evidence/` and `evidence/__pycache__/` remain. `approved_unchanged` (`build.ex:219-227`) then fails again, and the Build doesn't reach acceptance. — Fix: report the topmost added entry (`…/<slug>/evidence`), have the fake `rm -rf` the listed paths, and rewrite "exactly the three paths".

- **[BLOCKING] `.claude/**` also covers Claude Code's own runtime files.** `.git/info/exclude:7-17` lists `.claude/scheduled_tasks.lock`, `worktrees/`, `checkpoints/`, `mailbox/` and others. Control already has `.claude/scheduled_tasks.lock` (lessons 14 and 19). These ignored files still count as changes (`guarded_paths.ex:95-100`), so a real Claude Developer's harness write becomes a terminal `protected-path` stop. The fakes never write them, so the proof is hollow. — Fix: protect only the config Claude loads (`.claude/settings*.json`, `.claude/hooks/**`, `agents/**`, `commands/**`, `skills/**`), rework the rest, and add a runtime-lock case.

- **[BLOCKING] The draft misreads `approved_mutation_test`.** All 9 cases mutate the copy during the `check`, target or Reviewer phase (`approved_mutation_test.exs:11,100-101,159-165`), never in a Developer turn. They are caught by `bound_inputs_unchanged` (`build.ex:1249,1480`). "Additions now expect rework" is either impossible or would resume the Developer for a write by the Reviewer or controller. — Fix: leave that file unchanged (drop it from the guards) and add a Developer-turn addition case to the new test. State that additions found at Review or publication stay `integrity`. Lesson 21 itself was caught "at publication", so say whether it is actually covered.

- **[ADVISORY] Case (f) contradicts itself.** Today, a failed turn with a violation stops with the guard message, category `integrity` (`build.ex:770-771,1172-1173`), not the harness-failure message. `core_integrity_test.exs:206,215` depends on this. — Fix: state the exact message and category.

- **[ADVISORY] Stop categories: old and new mechanisms may coexist.** `stop/3`'s third argument is `details` (`build.ex:1628`). If the `@stop_categories` prefix table (`build.ex:1661-1679`) stays for the other categories, two mechanisms run side by side (rule 44). — Fix: say whether prefix matching is removed entirely.

- **[ADVISORY] `offline_retries` isn't defined anywhere yet.** Nothing on main defines it, and the fixture config (`workspace_fixture.ex:19-33`) is outside the guards. — Fix: state how the test sets it to 2, and whether the counter is per attempt or per Build across Reviewer reworks.

- **[ADVISORY] Mixed violations have no stated precedence.** A stray path in the same turn as a protected or modified Approved path could go either way. — Fix: say that terminal wins.

No violations of D1, rules 36/37 or §1.16: nothing auto-approves or notifies, and the new returns have a caller.

## Verdict: not ready
