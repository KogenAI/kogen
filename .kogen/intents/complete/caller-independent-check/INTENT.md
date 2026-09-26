# Make the offline suite independent of the caller's KOGEN_LIVE_LOG_DIR

## Why

Since 7ed41f66 (isolated-candidate-workspace) the controller sets `KOGEN_LIVE_LOG_DIR` for every
target it runs, `check` included (`lib/kogen/build/verification_runner.ex:112-120`). The rule is
right for live targets: evidence must survive the Candidate's removal. But offline fixtures in
`test/kogen/candidate_verification_test.exs` and `test/kogen/verification_reuse_test.exs` run a
nested controller in the test VM. That nested controller sees the outer value as "caller-set",
honours it, and sends the fixture's markers to the outer Build's directory. Seven tests then fail,
so `check` fails for every Build on `main`. Build KBv11qlQdFqPH3rjL0f30J2V (shaping-quality)
burned three cycles on it; its Developer could not touch these files.

## Outcome

`check` passes whether or not its caller set `KOGEN_LIVE_LOG_DIR`, and production behaviour is
unchanged. `WorkspaceFixture.build!/2` and a new `VerificationCycleFixture.run_cycle/4` run as if the
caller had no live-log directory. For `build!/2`, a test that passes its own `:env` value still
wins; `run_cycle/4` has no override (no caller needs one).
Two regression tests reproduce the controller-set condition inside any `check`. A reference
implementation was prototyped and run on 7ed41f66 (`evidence/prototype-2026-09-26.diff`).

## Non-goals

- No change under `lib/` or `priv/`, to the Makefile, `scripts/` or `test/test_helper.exs`, and no test-reliability registry row.
- Other nested-controller fixtures (scripted, controller, integrity) are untouched; they never read the variable.
- No global clearing of `KOGEN_LIVE_LOG_DIR`. Live targets need it.
- No paid target.
