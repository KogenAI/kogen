# Probe P3: the Candidates at develop e65392cf

Date: 2026-09-27, after the Opus slice-1 review (round 1). Run in a disposable directory outside the repository
(`<scratchpad>/sq-split/probe/qbtree-e65392cf`). The checkout was not touched (`git status --short` empty after), and
no global tool state changed: mise trust through `MISE_TRUSTED_CONFIG_PATHS` for each command only, the git identity
through `-c` flags, `deps` symlinked to the checkout's, `_build` copied from the P1 tree.

## P3a: does each hunk still apply at e65392cf?

`GIT_INDEX_FILE=<tmp> git read-tree e65392cf5d9265f0e0e9c8dae1e078ba4ddfb533`, then `git apply --cached --check` on
each per-file diff (`apply-check-*.tsv`). The results are identical to P0 at 3531023d:
- qbOzahf8: 164 of 166 apply; only `.kogen/config.yaml` and `README.md` fail (as before).
- ZujYgSGt: 160 of 175 apply; the same 15 files fail. `lib/kogen/build.ex` hunk 2 (the publication subject) still
  applies alone; hunk 1 fails at `lib/kogen/build.ex:49`.
- `verification_plan-proof_errors-only.diff` (qb's `verification_plan.ex` diff cut to hunk 1, lines 1-96: only
  `proof_errors/4`, without `require_no_extra_targets/2`) applies.

## P3b: the gate stages on the qb files

`git archive e65392cf | tar -x`, a local commit, then every applicable qb file diff applied (164 files; the qb
`.kogen/config.yaml` and README hunks were not applied). Then the stages of `scripts/check/offline.py`:

| Stage | Result | Log |
|---|---|---|
| `mix format --check-formatted` | exit 0 | `p3-format.log` |
| `mix compile --warnings-as-errors --force` | exit 0 | `p3-compile.log` |
| `mix credo --strict` | exit 0, "218 source files … found no issues" | `p3-credo.log` |
| `mix test --exclude test --warnings-as-errors` on the two audit test files | exit 0 (0 run, 46 excluded) | `p3-test-compile.log` |

`mix test` on `shaping_audit_checks_test.exs`, `shaping_audit_task_test.exs`, `verification_policy_test.exs`,
`selective_verification_targets_test.exs`, `commit_provenance_test.exs` and `intent_test.exs`: 133/135 passed in
19.3 s (`p3-mix-test.log`). The two failures are outside slice 1: `intent_test.exs:108` expects the codex route's
`auditor` (slice 2; the config hunk was not applied), and the README test (the README hunk does not apply).

What P3 does not show: that the slice-1 trimmed files pass. It ran qb's files whole (including `questions.ex`, the
Jev, auditor and Stop-hook modules). The Developer runs `mix format`, `mix compile --warnings-as-errors` and
`mix credo --strict` on the trimmed files before ending every turn.
