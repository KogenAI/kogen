# Shaping investigation (2026-09-24, shaped against main 2909f557)

## Observed failure

This comes from `state.json` in the retained record (see references.yaml),
read with a Python script during Shaping:

- There were 3 cycles, all with Candidate `69e499f375…`, and the terminal state was `exhausted`.
- Each cycle ran `check` (passed), then `live-native` (failed). Their finish times were
  14:01:57/14:09:08, 14:12:45/14:17:08 and 14:20:45/14:27:14 UTC.
- The failing case was always `Kogen.Codex.CompatibilityTest` "selected authenticated
  managed runtime passes the bounded compatibility runner" (4/5 live cases passed).
  The cause was `{:compatibility_turn, :launch_reviewer | :launch_developer,
  {:provider_exit, 124, ...}}` ("Kogen compatibility native turn timed out").

## Current mechanism (source)

- `.codex/hooks/stop_runner.py`: each Stop runs `make check` + targets and stops at
  the first failure. The receipt prefix must equal the target list, and every
  cycle restarts at `check`. The controller only validates the result
  (`lib/kogen/build/verification.ex` `settle/3`, `valid_receipts?/3`).
- Registrations: `priv/kogen/claude_code/settings.json`, passed with `--settings`
  (`lib/kogen/harness/claude.ex:121-135`), and `.codex/hooks.json`. Both run
  `$(git rev-parse --show-toplevel)/.codex/hooks/check.sh`, so they read the
  Candidate's own scripts.
- `Kogen.Harness.resume_build_developer` (`lib/kogen/harness.ex:67-77`) already resumes
  the exact Developer for outer resumptions.
- `VerificationPlan` requires Makefile/catalog set equality, a rehearsal for each
  provider-backed target, and `verified_by == ["check", paid_target]` with
  paid_target in the catalog, validated before launch
  (`lib/kogen/build/verification_plan.ex:136-150,203-216`; `lib/kogen/build.ex:203-207`).
- The live owners in the three live-native files are independent (no shared setup).
  The existing rehearsal pieces split naturally: `prepare_fixture` goes to
  compatibility and `LiveNativeReceiptAudit.audit!` to helpers. The runtime owner
  has no existing rehearsal.
- `lib/kogen/codex/compatibility.ex` copies check.sh/stop_runner.py into its fixture
  and requires `hook_receipt`, `checks` and `checks_before_resume`. It already settles
  `:timed_out` through `Kogen.Codex.ProviderOutcome`.
- `live_shape_to_build_test.exs` asserts failed-then-passed Stop history (lines ~379, 459).
- In `priv/kogen/test-reliability.yaml`, the `target` strings are not validated by
  `test/support/test_reliability_catalog.ex`. The ledger is generated from a
  historical coverage matrix.

Two read-only kogen-worker helpers (claude-sonnet-5, medium) mapped the Stop route
and the target split. The root checked the consequential claims above against
the source.

## Pre-launch contract probe

Command (read-only, from the repository root at 2909f557):
`mix run --no-start -e` calling `Kogen.Build.Contract.load(".kogen/intents/drafts/fortify-paid-verification")`,
then `Kogen.Build.VerificationPlan.build(scenarios, may_change_guarded_paths, VerificationPlan.load())`.
Result: the contract loaded `{:ok, ...}` and the plan returned `:ok` against the current catalog.
Limitation: this ran on the Draft path rather than `approved/`, and it doesn't
check that the new offline proof selectors exist. `controller_verification_test.exs` and
`verification_reuse_test.exs` are Developer-created, and the controller counts a missing
one as unfinished work.

## Bootstrap findings (review of the co-edited revision)

- Searching `lib/` for `Code.compile/require/load`, `:code.load/purge` and
  `recompile` found no matches. The Build controller runs only the code it
  started with, so main's controller can't call a verifier the Candidate adds.
  It settles only through `Kogen.Build.Verification.settle/3`, which reads
  Stop-written state.
- `lib/kogen/codex/compatibility.ex:513-518` clears `KOGEN_VERIFICATION_CONTEXT` and
  `KOGEN_TRACKING_CONTEXT` for its nested fixture, so the fixture relies on the
  Stop runner's no-context mode. Making that mode a no-op therefore requires the
  fixture's Stop portion to go in this Intent.
- After the two-step revision, the contract and plan probe was re-run with the same
  command as above: contract `{:ok, ...}`, 7 scenarios, plan `:ok`.

## 2026-09-25 continuation: reconciliation after failed Build G8XQmw8OuNa-fPqe0TlQ0p35

- **Failed Build:** the record is at `.kogen/runtime/scenario-tracking/G8XQmw8OuNa-fPqe0TlQ0p35/record.json`.
  The Developer made no changes and objected to `narrow-native-targets` and
  `self-hosting-settlement`. Jev (jev-1.13.0) returned `objection` at confidence
  1.00, and the Build stopped with `cannot_comply` before Review. `check` and
  `live-shape-to-build` passed on the unchanged Candidate `8deff892…`.
- **Checked against source:** after each Developer turn, main's controller runs
  `post_developer_inputs_unchanged/1` (`lib/kogen/build.ex:610-619`). That calls
  `VerificationPlan.unchanged?/1` (`lib/kogen/build/verification_plan.ex:105`,
  a byte comparison with the catalog read at admission). Before each Developer
  launch or resume it runs `VerificationPolicy.preflight/2`
  (`lib/kogen/verification_policy.ex:28-40`). That requires
  `.codex/hooks/verification_policy.py`, `.codex/hooks/check.sh` and the
  PreToolUse registration in `.codex/hooks.json`.
- **Nested-context hazard (new finding):** `.codex/hooks/stop_runner.py:180`
  runs `make -C ROOT <target>` with the inherited environment, so the outer
  `KOGEN_VERIFICATION_CONTEXT` reaches it.
  `test/kogen/live_shape_to_build_test.exs:297-304` runs the nested
  `mix kogen.build` without clearing that variable. Today main's nested
  controller overrides it for its Developer
  (`lib/kogen/build/verification.ex:88`). A new controller that only omitted it
  would leak the outer v1 context into the fixture's Stop hook. The contract now
  requires explicit removal and a planted-context control.
- **Scope change (Shaper):** no Makefile, catalog or ledger changes. The
  `narrow-native-targets` scenario was removed, and those three paths were
  dropped from `may_change_guarded_paths`, so the guarded-path check enforces
  it. The target split, Stop deletion and the compatibility owner's paid proof
  go to `cross-harness-adversarial-roles`.

### Build preflight probe (read-only, repository root, main 2909f557)

`mix run --no-start -e` executed the same calls as `Kogen.Build.run/2` and
`do_build/4`, against the Draft base, not `approved/`:
`Kogen.Intent.read/2` → `{:ok, …}`; `Kogen.Build.Contract.load/1` → ok, 6
scenarios; `VerificationPlan.load/0` + `build/3` → `:ok`, targets
`["check", "live-shape-to-build"]`; `VerificationPolicy.preflight/2` → `:ok`;
`Git.reject_candidate_blinding_index_flags/0` → `:ok`; the Makefile declares
`check`. The package is 60 KB, far under the publication budget.
Limitations: `read_approved_entries`, `Tracking.new`, the lock, the clean
worktree, `check_complete_absent` and `Jev.key_present` weren't exercised. The
package isn't under `approved/`, and those depend on launch-time state. The
probe doesn't check that the Developer-created offline selectors
`controller_verification_test.exs` and `verification_reuse_test.exs` exist.

## 2026-09-25 continuation, later turn: recorded paid-verification cost

This comes from a Python read of every
`.kogen/runtime/scenario-tracking/*/verification/*/state.json` (117 Build
records, 80 with cycles, 446 receipts). Receipts have no start time. A paid
target's duration is its `finished_at` minus the previous receipt's
`finished_at` in the same cycle. `check` duration comes from its
`/usr/bin/time -p` real time.

| target | runs | median | max | total |
|---|---|---|---|---|
| check | 237 | 1.1 m | 6.2 m | 6.0 h |
| live-native | 71 | 4.1 m | 10.1 m | 4.1 h |
| live (retired) | 47 | 5.1 m | 42.6 m | 4.8 h |
| live-shaping-quality | 14 | 5.8 m | 10.2 m | 1.4 h |
| live-shape-to-build | 9 | 3.9 m | 7.4 m | 0.6 h |
| live-reviewer-rework | 20 | 1.9 m | 12.5 m | 1.0 h |
| cold-offline | 37 | 2.0 m | 3.0 m | 1.2 h |

The total across all Builds is 19.5 h of verification time. The largest
per-Build verification totals were 57 min (`recover-failed-builds`, 3 cycles),
47 min and 44 min (`harden-whole-test-suite`), and 32–38 min
(`isolated-candidate-workspace`, several Builds). `named-routes` ran
`live-shape-to-build` in three passing cycles; its window from the first cycle
to the last finish was 64 min.
Limitation: whole-Build wall time (Developer turns and Review) can't be read
reliably from these records. A timestamp-span estimate mixed in unrelated
timestamps, such as approval dates, and was discarded.

## Hardcoded `check` inventory (source, main 2909f557)

`lib/kogen/build.ex:191` (admission requires a Makefile `check`), `:393`,
`:522`, `:789`, `:859`, `:1245` (a separate `attempt["check"]` receipt), and
`:1313-1321` (report text); `lib/kogen/build/verification_plan.ex:67,122-128,213-215`;
`lib/kogen/build/verification.ex:33`; `lib/kogen/build/report.ex:44`;
`lib/kogen/check.ex:67,101-115,189-191`; `lib/kogen/verification_policy.ex:17`
(the guard always adds `check` and `live`). The catalog already carries
`provider_backed`, `dependencies` and `owner` for every entry, so the gate rule
can be expressed without names and without changing this Build's catalog.

## 2026-09-25 continuation, third turn: Make and live-test selection

- Make is hardcoded in: `lib/kogen/check.ex:131-135` (`System.cmd("make", [name])`)
  and `:96-123` (names validated against the Makefile);
  `lib/kogen/verification_policy.ex:46` (the guard's instruction text); and
  `.codex/hooks/verification_policy.py:91-160` (the guard recognizes only `make`
  goals). The catalog entry schema has no runner field today.
- The push toward live tests is in the shared prompt,
  `priv/kogen/prompts/shaping.md:105-112`, which says to "Select targets by
  affected existing workflows and evidence sufficiency, even when their live
  test files are unchanged". Prompt contract tests that reference the shaping
  prompt: `test/kogen/scenario_contract_test.exs`, `test/kogen/shape_task_test.exs`,
  `test/kogen/execution_policy_test.exs`.
- A re-run of the preflight probe (same calls as before, Draft base) gave all
  YAML ok, `Contract.load` with 9 scenarios, plan `:ok` with targets `["check"]`,
  and `VerificationPolicy.preflight` `:ok`.

## 2026-09-25 continuation, sixth turn: live-native failure classes since the GPT-6 upgrade

This comes from the `live-native` receipt `output` in `state.json` files
finished on or after 2026-09-24. There were 9 runs: 1 pass (YmvihNr7) and 8
failures, all in `Kogen.Codex.CompatibilityTest` "selected authenticated
managed runtime passes the bounded compatibility runner". The other native
live cases passed.

| class | runs | signature |
|---|---|---|
| credential-store setup | 2 (l5Ur, GV9F) | `require_login` → "unexpected discovery settings in Kogen credential store: …/accounts/shared/config.toml" (~1 s) |
| Shaping turn failed | 2 (l5Ur, GV9F) | `interactive_shaping_failed`, status 1, marker false (~185 s) |
| native turn timeout | 4 (GV9F, btwokrNx ×3) | "Kogen compatibility native turn timed out" (240 s per-turn budget, `bounded_exec.py:196`). Before it, the Codex tool router logged `skill package is not available`, the expected PreToolUse block of `make check`, and once `exec_command failed … No such file or directory (os error 2)` |

So the problem isn't just the budget. At least three distinct failure classes
exist, and the timeout class follows Codex tool-router errors. Per-turn raw
logs weren't retained in the receipts. Codex session rollouts for 2026-09-24
exist in the managed credential store (`…/Kogen/codex/accounts/shared/sessions/2026/09/24/`).
They are private raw harness logs, not copied here. The owning Shaping session
can inspect them.
