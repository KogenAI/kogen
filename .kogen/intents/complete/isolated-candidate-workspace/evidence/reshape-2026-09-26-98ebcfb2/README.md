# Reshape against main 98ebcfb2 (2026-09-26, continuation visit)

Shaper direction in this conversation: "reshape against the latest head etc." and "always probe
what needs probing". 98ebcfb2 ("Switch Keychain item for Jev") renames the Jev Keychain service
from `ai.typesafe.api` to `dev.kogen.jev` in README.md, lib/kogen/jev.ex,
priv/kogen/test-reliability.yaml and five tests.

## Contract
- No scenario, risk or outcome names the Jev service. Every Keychain reference here concerns
  harness logins. Jev runs in the controller, outside the role write boundary.
  `lib/kogen/jev.ex` is not guarded and needs no change.
- No line anchor in the package points into a file 98ebcfb2 changed (grep of INTENT.md,
  scenarios.yaml, risks.yaml, questions.md, decisions.md); only path references.
- `validate-draft.txt`: `validate.exs` run with `mix run --no-start` at 98ebcfb2 on the draft:
  Intent.read :ok, Contract.load :ok, VerificationPlan.build :ok (targets check,
  live-reviewer-rework, live-shape-to-build; every scenario `integrity-not-configured`, as at
  9ff7af6e), VerificationPolicy.preflight :ok, 14 scenarios, 15 risks.

## Stashed Candidate rebase probe
Disposable detached worktree at 98ebcfb2 in the session scratchpad (removed afterwards; control
untouched). Applied `git diff 9ff7af6e d1c4f00bb7 --binary | git apply -3` plus
`git archive d1c4f00bb7^3 | tar -x`.
- Conflicts: `test/kogen/build_preconditions_test.exs` (keep the Candidate's
  `Kogen.Build.run(@slug, nil, dir)` call, main's `dev.kogen.jev` strings) and
  `priv/kogen/test-reliability.yaml` (generated one-line JSON: take the Candidate's file, then
  `python3 scripts/check/refresh_test_reliability_sources.py`; it rebound
  build_preconditions_test, controller_handoff_test, core_integrity_test and jev_test; `--check`
  then exit 0). No `ai.typesafe.api` left in lib, test, priv or README.md.
- `MIX_ENV=test mix compile --warnings-as-errors`: exit 0.
- `mix test` build_workspace, build_preconditions, jev, core_integrity, controller_handoff tests:
  440 passed, 0 failures (`focused-tests.log`). KOGEN_* and MIX_BUILD_PATH/MIX_DEPS_PATH/MIX_EXS
  were unset; deps were APFS-cloned from control.
- Limitation: not `make check`, no live target, no Build; the Candidate still has the
  8Bs51yZP defect.

## Binding-order defect (Review finding of 8Bs51yZP)
Confirmed in the rebased Candidate: `lib/kogen/build.ex:543-545` calls
`Kogen.Harness.open_roles/4` and only then `Workspace.bind/2`; `Workspace.create` writes the
owner record first with the empty list. The only binding assertion,
`test/kogen/build_workspace_test.exs:138`, reads the owner record after the run, so the focused
suite passes with the defect. Hence scenario `candidate-creation` now requires nonempty bindings
before open_roles/readiness and an ordering assertion made from inside a fake readiness step.
