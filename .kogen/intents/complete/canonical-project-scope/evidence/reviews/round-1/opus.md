## Findings

- **[BLOCKING]** Deleting `Workspace.canonical/1` breaks compilation, because callers outside the guarded paths still use it. They are `lib/mix/tasks/kogen.expert.ex:132`, `test/support/workspace_fixture.ex:110`, `test/support/live_reviewer_rework_fixture.ex:193`, `test/kogen/harness_role_test.exs:165,325`, `core_integrity_test.exs:441`, `live_shape_to_build_test.exs:622,676` and `build_workspace_test.exs:103,110,200`. This also contradicts scenario `plain-paths-unchanged`, which says "existing tests … pass unedited" (`scenarios.yaml:16`). Widening the guards costs more than it looks: three of those tests are source-bound in `priv/kogen/test-reliability.yaml` by `source_sha256` (`test/support/test_reliability_catalog.ex:144-148`). One of them, `live_shape_to_build_test.exs`, is a live owner, so editing it forces a paid target (DIRECTION 1.11, D8). — Fix, recommended: keep `Workspace.canonical/1` and implement it on top of `Kogen.ProjectScope.canonical/1`. That is shared code, not a deprecated path. Otherwise, add all of the files above, `kogen.expert.ex`'s Boundary `deps`, the catalog, and the paid target to the Intent.

- **[BLOCKING]** The fixture in scenario 1 can't be created inside a Build. The write boundary only allows writes to the Candidate, the harness home and the per-Build tmp dir (`lib/kogen/build/write_boundary.ex:261-271`), so a fixture "created under /tmp" is denied. Kogen also sets `TMPDIR` to the canonical tmp dir (`write_boundary.ex:346`), so `System.tmp_dir!()` already returns the canonical path. And on a host where `/tmp` isn't a symlink, the six ids match trivially, which proves nothing. — Fix: create the directory under `System.tmp_dir!()` plus a `File.ln_s` alias next to it, then check that the alias and the real path give the same id. Also state the TMPDIR rule for the Developer (lessons #20).

- **[BLOCKING]** The `auth-scope` risk claims the delegation covers this change (`risks.yaml:6-8`). Rule 24 allows that for login rows only "when existing logins keep working through expand-then-contract". Rule 44 removed expand-then-contract, and this Intent deliberately makes legacy selectors fail. Login scope is a protected class under D1. — Fix: route it to QUESTIONS.md for explicit human approval, or drop the behaviour change (see the next finding).

- **[ADVISORY]** The legacy-selector error can never fire from real use (§1.16), so its proof tests nothing real. Every Kogen writer already keys selectors by the physical path:
  - login uses `File.cwd!()` (`claude_code.ex:338`, `codex.ex:250`), which is getcwd's physical path;
  - Build canonicalizes the control path (`build.ex:133-143`);
  - Shape passes `File.cwd!()` (`harness.ex:143`);
  - the evaluation driver already uses `resolve()` (`test/support/shaping_evaluation/driver.py:162`).
  
  The error only fires on a hand-made fixture. Under fakes, Codex skips scope resolution entirely (`codex.ex:29-42`, `KOGEN_HARNESS` gives `scope: nil`). — Fix: remove `legacy-selector-fails-loudly`, or name a real caller that can produce a legacy selector.

- **[ADVISORY]** Scenario 3 says the call "raises". The public APIs catch the exception and return `{:error, msg}` instead (`claude_code.ex:68-69,98-99,228-229`, `codex.ex:216-217`). — Fix: reword the scenario to expect the error return.

- **[ADVISORY]** The "Why" has no evidence behind it. `evidence/` doesn't exist in the Draft, and `references.yaml` cites only a ROADMAP row. — Fix: cite the actual caller or failure that passed a symlinked path.

- **[ADVISORY]** The claim that existing tests pass unedited isn't in the proof map. `proof.offline` lists only `project_scope_test.exs`. — Fix: add `build_workspace_test.exs`, `build_preconditions_test.exs:550`, `harness_home_test.exs:202` and `candidates_command_test.exs:456`.

- **[ADVISORY]** "…temp_dir/1 agree" can't be tested as written: `temp_dir/1` takes a build_id, not a path (`workspace.ex:79`). — Fix: drop the clause.

- **[ADVISORY]** The fallback for a path that doesn't exist yet means a path under a symlinked parent (`/tmp/new`) changes id once it's created, and scenario 2 locks that in. — Fix: canonicalize the nearest existing parent and append the rest.

- **[ADVISORY]** The Draft's anchors may be stale. `shaped_against.branch: develop` (`intent.yaml:7`) doesn't match the `main` it will be built on. — Fix: re-check the cited lines once shaping-quality, build-reliability and guard-violation-rework have landed.

- **[ADVISORY]** The Workspace docs describe the id as the "expanded control path" (`workspace.ex:11-12,45-46`). That file is guarded, so update it there. README:657 describes the login scopes, and a new user-visible error would need that section updated, but README isn't guarded.

The Boundary plan itself is sound: a `ProjectScope` with no dependencies avoids a cycle, because ClaudeCode and Codex can't depend on `Kogen.Build`.

## Verdict: not ready

I couldn't write the plan file this session asked for, because no write tool was available.
