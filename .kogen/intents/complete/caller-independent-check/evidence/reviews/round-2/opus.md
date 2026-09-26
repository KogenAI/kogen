## Findings

- **[ADVISORY] `check` can't prove all of scenario 1's `when`/`then` as written.** The `when` describes two `mix test` runs, one with the variable unset and one set to "an existing outer directory". The `then` says "the outer directory stays empty". The Build's `check` makes only one run, and in it the outer directory is the outer control's `.kogen/runtime/live-evidence`. That directory is shared and may already hold evidence from earlier live runs (`cold_offline_test.exs:17-21` writes there too, for example). A strict Reviewer could read "stays empty" literally and object. — `scenarios.yaml:12-15, 43-45` — **Fix:** make the `then` say that the fresh outer directory each regression test creates stays empty. Keep the "unset" run as probe evidence only.

- **[ADVISORY] The probe reproduced the environment variable, not the real controller.** It ran `KOGEN_LIVE_LOG_DIR=… make check` by hand in a detached worktree. It didn't run inside a Candidate worktree with a harness home under the 7ed41f66 controller. No Build has yet passed `check` under that controller. If a failure shows up only under the real controller, it would sit outside these guarded paths. — `evidence/probe-2026-09-26.md:9-19`, `risks.yaml:16-21` — **Fix:** cite the `check` receipts from Build KBv11qlQdFqPH3rjL0f30J2V showing exactly these 7 failures and nothing else, as lesson 18 asks.

- **[ADVISORY] `risks.yaml` overstates what the other fixtures do.** It says `scripted_build_fixture.ex`, `controller_build_fixture.ex` and `integrity_fixture.ex` "may write into the outer Build's live-evidence directory". But none of them references `$KOGEN_LIVE_LOG_DIR`. The only readers are the two fixtures fixed here, `live_reviewer_rework_fixture.ex:229` and live-tagged tests. — `risks.yaml:9-15` — **Fix:** say those fixtures write nothing there. That also makes the INTENT title's claim true.

I checked each part of the brief and found nothing blocking:

- **Guarded paths are enough.**
  - None of the four files is in `priv/kogen/` (0 matches).
  - `Catalog.discover/1` is never called (`test_reliability_catalog.ex:168`), so new tests needn't be registered, and the 346 count in `test_reliability_catalog_test.exs:16` doesn't change.
  - Kogen's own catalog declares no `verification_surface`, so the surface ledger doesn't apply (`ledger.ex:30`).
  - `rehearsals.exs:3-45` only searches source text for symbols.
  - `selective_verification_targets_test.exs:48-55` is only affected if a new test adds `@tag :live`.
  - `compiled_fixture.exs:23` and `lifecycle_test.exs:884` copy `workspace_fixture.ex` as a whole, so the edit is harmless.
  - Both proofs pass the `valid_proof?`/`valid_reason?` checks (`verification_plan.ex:414-462`).
- **The environment fix works within these paths.** `live_log_dir/1` reads `System.get_env` in the child VM (`verification_runner.ex:113`). `with_env/2` deletes the variable for the call and restores it afterwards (`workspace_fixture.ex:229-241`). Because `previous` is captured before any change, the caller's `:env` entry still wins over the prepended nil, and the outer value comes back afterwards.
- **The regression design holds.** `async: true` is correct: `isolated_case.ex:16` forces it, and `isolation_test.exs:173` requires it. `put_env` in a test body only runs in the child VM (`isolated_case.ex:54-66`). The candidate regression is red on 7ed41f66 (its marker goes to the outer directory). The reuse regression catches a wrapper that just passes the call through: `calls/1` would be `[]`.
- **The prototype diff matches the scenarios.**
  - Nil comes before `:env` (diff lines 167-172).
  - All six `run_cycle` calls go through the fixture.
  - Both regressions assert the control marker, an empty outer directory and a restored variable.
  - It stays within the Credo alias depth (`.credo.exs:85-86`). `WorkspaceFixture` is on the child's code path through the test_helper cache (`test_helper.exs:65-69`).
- **No conflict with DIRECTION §1.16–1.19.** `run_cycle/4` has callers (§1.16). Nothing is split off (§1.17). The proof is the cheapest offline check (§1.19).

## Verdict: ready
