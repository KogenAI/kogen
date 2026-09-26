# Prepare-command probes (P6a-P6e) — offline, disposable clone

Clone: /private/tmp/claude-501/.../scratchpad/probe/prepare/kogen (cloned from
/Users/almirsarajcic/Areas/Kogen/kogen, deps+_build rsynced in). No provider
sessions were started; all commands ran with `mix run --no-compile --no-start`,
`python3`, or `mix compile` only. Real checkout was never touched.

## P6a — standalone "prepare" sequence, no provider dispatch

- live-shaping-quality: `test/support/shaping_evaluation/driver.py:setup_fixture`
  (~344) is already fully standalone: rsync copy, `evidence/prerequisite_control.py`,
  git init/commit, `mix compile --warnings-as-errors`. Invoked directly
  (`python3 -c "import driver; driver.setup_fixture(...)"`) with
  `test/support/{codex,claude}` PATH-shim binaries prepended and
  `KOGEN_PROVIDER_DENIAL_RECEIPT` set: exit 0, **4.05s wall**, shim receipt
  never created — confirms no provider call. `main()`'s case dispatch calls
  `setup_fixture(...)` then `drive(...)`; `drive()` is where the first
  provider (`expect`+native CLI PTY) is spawned, so "prepare" = everything up
  to (not including) that call.
- live-reviewer-rework: `test/support/live_reviewer_rework_fixture.ex:run/0`
  (51-90) does `assert_outside_checkout!` (44, canonical `pwd -P`),
  `assert_logged_in!`/`assert_codex_logged_in!` (83-84, delegate to
  `Kogen.ClaudeCode.open/2` / `Kogen.Codex.open/2` — local readiness only,
  open+close, no provider dispatch), `setup_fixture` (182, rsync+git),
  `precompile!` (218, `mix compile --warnings-as-errors`), `write_package!`,
  and local `VerificationPlan`/`Contract` checks — all before the single
  provider call, `System.cmd("mix", ["kogen.build", ...])`. All of this is
  independently callable and local.
- live-native: `Kogen.Codex.Compatibility.prepare_fixture` was not
  independently re-verified with a prototype run in this pass (time-boxed);
  based on file inspection it is fixture-setup-only (no `codex`/`claude`
  invocation) but this should get its own standalone invocation check before
  being relied on.

## P6b — defect (a): `.kogen/build.lock` copied by driver.py today

- Confirmed live: seeded `.kogen/build.lock` in the clone, ran
  `driver.setup_fixture("csv-flawed", ...)` unmodified → `build.lock` **was**
  copied into the fixture (`copied build.lock? True`).
- `test/support/live_reviewer_rework_fixture.ex`'s own `setup_fixture/2`
  already has `--exclude=.kogen/build.lock` — driver.py is the one target
  missing it.
- `Kogen.Build.GuardedPaths` (`lib/kogen/build/guarded_paths.ex:4`) exposes the
  authoritative list: `@volatile ~w(.kogen/runtime .kogen/build.lock
  .kogen/codex .codex/sessions _build deps cover .elixir_ls)`. Re-ran with a
  patched `setup_fixture` deriving `--exclude=` flags from that exact list:
  `build.lock` and `.codex/sessions` are both excluded (`False`/`False`).

## P6c — defect (d): non-canonical `/tmp` vs `/private/tmp` scope divergence

- `Kogen.Codex.State.project_id/1` and `Kogen.ClaudeCode.project_id/1` both
  hash `Path.expand(project)`, which does **not** resolve symlinks (unlike
  `pwd -P`/realpath). Empirically, for the identical directory:
  - `Kogen.Codex.State.project_id("/tmp/kogen-probe-X")` = `c70a0210...`
  - `Kogen.Codex.State.project_id("/private/tmp/kogen-probe-X")` = `94959c4b...`
    (different hash, same physical directory).
  - Same divergence reproduced for `Kogen.ClaudeCode.project_id/1`.
- Concrete scope-selection consequence (Codex): after
  `Kogen.Codex.State.select_scope!(root, "/tmp/kogen-probe-X", :project)`,
  `scope_name(root, "/tmp/kogen-probe-X")` → `:project`, but
  `scope_name(root, "/private/tmp/kogen-probe-X")` (same dir) → `:shared`.
  A `:project` scope selection is invisible through the canonical path form.
- `Kogen.Codex.effective_scope/1` / `Kogen.ClaudeCode.effective_scope/1`
  currently returned `:shared` for both forms in this environment only
  because no per-project preference file existed yet (default fallback) —
  the divergence only manifests once a `:project` scope has actually been
  selected, as shown above.
- `test/support/review_packet_audit.ex:canonical_path!/1` (28) uses `pwd -P`
  and `assert_outside_checkout!` returns that canonical (`/private/tmp/...`)
  form, which `live_reviewer_rework_fixture.ex` then feeds into
  `assert_logged_in!`/`assert_codex_logged_in!`. If a human/tool ever logs in
  or selects a project scope using the literal (non-canonical) `/tmp/...`
  path, the fixture's own canonicalization means its readiness check will
  look up a *different* scope/preference file than the one actually set —
  this is exactly the defect-(d) mismatch. No other `==` path comparisons in
  `test/support/*fixture*.ex` or `review_packet_audit.ex` were found to be
  affected (grep found none besides `assert_outside_checkout!`, which is
  itself already canonicalized).

## P6d — fast detection of "no scripted answer" (defect c)

- `driver.py:drive()` (721-970) already has a fast, local signal: it
  correlates native-CLI JSONL rollout turn completion
  (`user_turn_terminal`) with Draft-file content stability (3s dwell), not a
  fixed timeout. As soon as a turn completes and the Draft stabilizes, it
  checks `triggers[next_msg](text, root)`; a mismatch sets
  `outcome="inconclusive"` and breaks immediately (no full `MAX_SECONDS`
  wait) — this already covers "the model's answer didn't match the
  script" once a turn actually completes.
- What is *not* covered: if the model's turn never reaches JSONL
  `task_complete` (e.g. it's waiting mid-turn for more input in a way the
  harness represents as an incomplete turn), the driver has no early signal
  and falls through to the generic `MAX_SECONDS` timeout
  ("product turn did not complete before deadline") — it never inspects
  partial transcript content or PTY idle time to guess "this looks like an
  unscripted question." No PTY-idle-based signal is used anywhere in the
  polling loop (`pty.log` is written but never polled for silence).
- Verified offline: `test/support/shaping_evaluation/driver_rehearsal_test.py`
  fully fakes clocks/Popen/rollout files (no provider, no real CLI) and is
  invoked from `test/kogen/shaping_evaluation_test.exs:90-94` via
  `System.cmd("python3", ["-B", rehearsal], env: parser_env())`, where
  `parser_env/0` supplies `KOGEN_SHAPING_EVALUATION_ELIXIR_CODE_PATHS` (the
  compiled `:code.get_path()` as JSON) so the rehearsal's fake parser
  subprocess can decode. Ran directly with that env var set:
  **17/17 tests pass in 13.6s wall**, fully offline.
- Given the offline-only signals available (Draft file + JSONL rollout), a
  faster "no scripted answer" detector is feasible in principle (e.g. poll
  the rollout for new `response_item`/assistant text even without
  `task_complete`, and fail fast if none of the remaining triggers match the
  partial text after a short idle window) but was not prototyped end-to-end
  here — it would change `drive()`'s core polling loop and needs a live
  provider transcript shape to validate against, which is out of scope for
  an offline probe.

## P6e — driver no-cancel prototype (offline part)

Diff saved: `driver-no-cancel.diff` (81 lines, `run_suite()` only). Behavior:
removes the "cancel every other case on first failure" branch; all dispatched
cases are polled to completion within the existing `SUITE_SECONDS` deadline;
per-case results collected into `failures{}`; one `FAILED: <case>: <reason>`
line is printed per failed case (in `CASES` order); `suite-failure.json` now
holds `{"failed_cases": {...}, "cleanup_errors": [...]}` for every failed
case; `write_manifest()` is now attempted even when `failures` is non-empty
(best-effort, exceptions swallowed so the original failure record survives).

Verified with a standalone two-failing-case rehearsal (built on
`driver_rehearsal_test.py`'s own `DriverRehearsalTest` base class/mocks,
saved separately as `p6e_two_failures.py`, not committed to the tree):
- all 7 cases launched and polled to completion — `True`
- no `os.killpg` cancellation signals sent — `True`
- `suite-failure.json.failed_cases` contains both injected failures
  (`booking-flawed`, `stateful-complete`)
- stdout has one `FAILED: <case>: ...` line per failed case
- `write_manifest()` was called (mocked) even though the suite failed

**integrity.validate_manifest and a real failure manifest**: not exercised
end-to-end (would need full `drive()` runs producing real evidence, not just
mocked `Popen`). Static reading of
`test/support/shaping_evaluation/integrity.py:305-336` shows
`validate_manifest` iterates `for case in CASES` and unconditionally requires
`review-receipt.json`, `messages.json`, `public-transcript.json`,
`owned-session-metadata.json`, `draft/intent.yaml`, `draft/scenarios.yaml` for
**every** case — it does not special-case a failed/incomplete case. Since
`drive()` already copies the Draft/evidence/owned-session capture
unconditionally in its post-`try` capture phase (regardless of `outcome`),
a case that fails *after* its Draft was saved should still produce these
files and pass validation; a case that fails *before* any Draft is saved
(e.g. native startup timeout) will not have `draft/intent.yaml` and will
still break `write_manifest()`/`validate_manifest` even under the no-cancel
design. This residual gap should be flagged to the Shaping root before this
diff is used for a paid run.

**Regression found in the existing rehearsal suite**: running the full,
unmodified `driver_rehearsal_test.py` against the patched `driver.py` hangs
real wall-clock time in
`test_run_suite_dispatches_all_cases_before_collection_and_reaps_after_child_failure`
(confirmed: process still alive after 20s, killed manually) — that test's
mock leaves 4 of 6 non-failing cases' `poll()` returning `None` forever,
relying on the *old* immediate-cancel-on-first-failure behavior to end the
test quickly. Under the no-cancel design the loop correctly keeps waiting for
those (mocked) still-running siblings until the real `SUITE_SECONDS`
(~720s) deadline, since this test does not patch `time.monotonic`. All other
16 rehearsal tests exercised individually/via full-suite partial run passed
except one unrelated preexisting failure
(`test_composed_suite_uses_main_routes_and_real_drive_before_manifest`,
traceback not fully captured before the process was killed — needs separate
triage, may be preexisting/unrelated to this diff since MAX_SECONDS-related
parser dependency wiring was involved). **This means
`driver_rehearsal_test.py` itself needs an update (shorten the mocked
scenario's fake timeline or patch `time.monotonic`) before this diff can
land — it is not a defect in the diff, but a compatibility gap between the
diff and the existing test's assumptions.**

## Cleanup
All runtime scratch dirs (`runtime-p6a`, `runtime-p6b`), the ad hoc
`/tmp/kogen-probe-*` and `/tmp/rehearsal_out*.log` files, and any leftover
`.kogen/build.lock` probe files were removed. No rehearsal subprocess was left
running (checked via `ps aux | grep rehearsal`). The clone itself
(`$S/kogen`, ~1.0G with deps/_build) was left in place per the disposable-clone
instructions, with driver.py's P6e diff applied in-place (also captured as
`driver-no-cancel.diff`).
