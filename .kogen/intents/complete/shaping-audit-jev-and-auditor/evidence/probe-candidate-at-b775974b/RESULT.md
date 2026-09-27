# Re-preflight probes at develop b775974b (2026-09-27)

The checkout was read only. Everything ran outside it:
- `git apply --cached --check` used `GIT_INDEX_FILE=<scratch>/index` after `git read-tree b775974b`;
- the audit runs used a `git clone --no-checkout` of the checkout, checked out at b775974b, with `deps` symlinked
  (`<scratchpad>/sq2/probe/repo-b775974b`);
- mise trust came from `MISE_TRUSTED_CONFIG_PATHS` for each command only.

## P4a: does each qb file and hunk still apply?

- `apply-check-qbOzahf8-slice.tsv`: 74 of the 84 file diffs in `candidate-qbOzahf8-f4819c37-codex-slice.diff` apply.
  The 10 that fail:
  - `.kogen/config.yaml` and `README.md`, the same failures as at 3531023d;
  - `lib/kogen/harness.ex` and `lib/kogen/intent.ex`, because slice 1 landed some of their hunks;
  - six new files that slice 1 already created: `lib/kogen/shaping_audit.ex`, `shaping_audit/finding.ex`,
    `shaping_audit/questions.ex`, `shaping_audit/report.ex`, `lib/mix/tasks/kogen.audit.ex` and
    `test/kogen/shaping_audit_task_test.exs`.
- `apply-check-hunks.tsv`, per hunk:
  - config hunks 1, 3 and 4 apply, and hunk 2 does not;
  - harness hunk 1 (the Boundary export) does not apply because it has landed; hunks 2 and 3 apply;
  - intent hunks 1, 3, 4, 5, 6 and 9 apply, and 2, 7 and 8 do not.

  Intent hunks 6 and 9 are slice 1's `commit_subject` doc and `optional_string/2`. They apply only because slice 1
  wrote them differently. Taking them would define `optional_string/2` twice, next to `lib/kogen/intent.ex:634`.

## P4b: slice 1's landed audit on this Draft

`mix kogen.audit shaping-audit-jev-and-auditor` ran in the probe clone with the Draft copied to
`.kogen/intents/drafts/`. That is the deterministic layer only, the landed slice-1 code.
- Revised Draft: `ready: e44ebd4c…`, exit 0, no finding. Route `claude` (the default); the report is in the probe.
- The same Draft without `priv/kogen/test-reliability.yaml` in `may_change_guarded_paths` gave `not_ready`, exit
  1, and one finding: blocking, mechanical `ledger-closure`. Its message was "test/kogen/harness_role_test.exs,
  test/kogen/intent_test.exs holds catalogued tests; … guarding the file is harmless". The Draft as shaped at
  3531023d had that gap.

## Not run

No `mix test` ran. The Candidate is not ported onto the landed slice-1 files, so the nine changed slice-1 tests and
the new tests have no run. `make check` in the Build is their first run.
