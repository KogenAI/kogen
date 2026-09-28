# Probe P0-P2: the Candidates at develop 3531023d

Date: 2026-09-27, while splitting `shaping-quality`. The runs happened in a disposable directory outside the
repository (`<scratchpad>/sq-split/probe/qbtree`). The checkout was not touched, and no global tool state
changed: mise trust was given through `MISE_TRUSTED_CONFIG_PATHS` for the one command only, and the git identity
through `-c` flags.

## P0: does each hunk still apply?

Setup: `GIT_INDEX_FILE=<tmp> git read-tree 3531023d`, then `git apply --cached --check` on each per-file diff of
both Candidates. `slices.py` splits the Candidates per file and per slice. The results per file are in
`apply-check-qbOzahf8.tsv` and `apply-check-ZujYgSGt.tsv`.

- **qbOzahf8** (`candidate-qbOzahf8-f4819c37-codex.diff`, codex Build, ported onto b2073666): 164 of 166 file diffs
  apply.
  - `.kogen/config.yaml`: hunks 1, 3 and 4 apply. Hunk 2 (codex `auditor`) fails because its context line
    `developer: {model: gpt-6-sol, effort: medium}` is `effort: high` since bf28f2ca.
  - `README.md`: the one hunk (95 added lines at old line 921) fails, because the kogen-ctx section now sits there.
    The text is a pure insertion and ports by hand.
- **ZujYgSGt** (`candidate-ZujYgSGt-555d0af3.diff`, Claude route, against 6dad9430): 160 of 175 apply. Of its
  failing files, these hunks apply alone:
  - `lib/kogen/build.ex` hunk 2 (the publication subject, diff lines 161-162);
  - `lib/kogen/harness/claude.ex` hunks 2-5;
  - `test/kogen/shape_task_test.exs` hunk 2 (the Claude helper tools);
  - `lib/kogen/intent.ex` hunks 2-8.

  `test/kogen/shape_task_test.exs` hunk 1 (the prompt assertions) conflicts with build-reliability's edits and
  ports by hand. Zuj's `driver.py`, `integrity.py`, `shape_transport.exp` and `driver_rehearsal_test.py` do not
  apply (they predate 82ac4351).

## P1: the qb Candidate's audit, Jev, auditor and config tests at 3531023d

Setup: `git archive 3531023d | tar -x`. Every qb file diff was applied except the two failing ones. The three
applicable config hunks were applied, and the codex `auditor:` line was added by hand after its `reviewer:` line.
`deps` was symlinked to the checkout's, a local commit made, and then:

```
MISE_TRUSTED_CONFIG_PATHS=$PWD mix test test/kogen/shaping_audit_checks_test.exs test/kogen/shaping_audit_task_test.exs \
  test/kogen/shaping_audit_jev_test.exs test/kogen/shaping_audit_question_gate_test.exs test/kogen/shaping_audit_auditor_test.exs \
  test/kogen/shaping_audit_flow_test.exs test/kogen/intent_test.exs test/kogen/harness_role_test.exs \
  test/kogen/configuration_support_contract_test.exs test/kogen/lifecycle_test.exs test/kogen/codex_environment_test.exs \
  test/kogen/claude_code_harness_test.exs test/kogen/commit_provenance_test.exs test/kogen/verification_policy_test.exs \
  test/kogen/selective_verification_targets_test.exs test/kogen/jev_test.exs test/kogen/scenario_tracking_test.exs
```

Result: 314/319 passed in 46 s (`p1-mix-test.log`). The 5 failures:
1. `shaping_audit_question_gate_test.exs:21` and
2. `shaping_audit_jev_test.exs:20` read `.kogen/intents/approved/shaping-quality/evidence/...`. That path is
   gitignored, so it is absent in a Candidate worktree, and it moves on landing. This is a latent defect: the
   tests would break after the package moved to `complete/` (slice 2 fixes it with in-repo calibration copies and
   pinned SHA-256s).
3. `shaping_audit_jev_test.exs:46` and
4. `shaping_audit_task_test.exs:761`: README claims. The README hunk was not applied (P0).
5. `lifecycle_test.exs:447`, assertion `:637`: `refute Map.has_key?(mutated, :auditor)` fails because qb's
   `normalize_role_route/1` merges `auditor: raw_auditor(route)` (nil) unconditionally. This is risk
   `codex-route-attempt-qbozahf8` defect (1), reproduced.

Everything else in the audit command, the deterministic checks, Jev, the question gate, the auditor, the flow, the
harness roles, the config contract, the Codex environment and the provenance tests passed. The provenance test is
the unchanged one: qb did not port the commit_subject assertions, and slice 1 takes them from Zuj.

What P1 does not show: that qb's rules are right where no test exercises them. Reading them found that the ledger
rule and its fixture use the removed `maintained_sources`/`source_sha256` format, that `prior-failures` reads
top-level `build_id`/`signature` keys real records lack, that `ledger-row-update-unstated` detects rows by the
substrings "delet" or "add", and that `build.ex` lacks the publication subject. Slice 1 specifies each.

## P2: the qb Candidate's hook, evaluation, prompt and prepare tests at 3531023d

The same tree, then:

```
MISE_TRUSTED_CONFIG_PATHS=$PWD mix test test/kogen/shaping_audit_hook_test.exs test/kogen/shaping_evaluation_test.exs \
  test/kogen/shaping_smoke_rehearsal_test.exs test/kogen/shape_task_test.exs test/kogen/harness_args_test.exs test/kogen/prepare_test.exs
```

Result: 73/80 passed in 5 min 42 s (`p2-mix-test.log`). The 7 failures:
1. `shaping_audit_hook_test.exs:941` and
2. `:975`: the live-shape-to-build probe expectations. qb never ported `test/support/shape_to_build_probe.exp`
   (Zuj has it, and it applies). This is risk defect (6), and it belongs to slice 4.
3. `shape_task_test.exs:337`: the Claude Shaper's agents now include Edit/Write, while the existing test asserts
   none. This is risk defect (2), and it belongs to slice 4.
4. `shaping_evaluation_test.exs:104` (transport controls): `free-text-panel/queued.ansi` is missing. Zuj has
   `free-text-panel/{opened,queued}.ansi`, and they apply. This is risk defect (4).
5. `shaping_evaluation_test.exs:93` (offline rehearsal): timed out after 300 000 ms. This is risk defect (3).
6. `shaping_evaluation_test.exs:208`: expects the fixture catalog to fail to load, but it loads. This is risk defect
   (5).
7. **New, not in the risk:** `prepare_test.exs:189` ("the shaping driver's prepare argv reports the one
   KOGEN_PREPARE_RESULT frame on a forced logged-out scope") fails with `driver.py: error: argument case: invalid
   choice: 'smoke'`. qb's `driver.py` dropped build-reliability's `--prepare` mode.

A comparison of the function and test names in `driver.py`, `integrity.py` and `driver_rehearsal_test.py` at HEAD
with qb's shows what the qb port lost:
- in `driver.py`: `run_prepare`, `prepare_login_scope_ok`, `prepare_toolchain_ok` (pinned by the catalog's
  `prepare_trace_assertions`), `resolved_codex_route`, `PARSED_YAML` and `TRANSPORT_COMPLETION_SUFFIX`;
- in `integrity.py`: `validate_failure_manifest` and `yaml_driver`;
- in `driver_rehearsal_test.py`, three tests:
  - `test_run_suite_dispatches_all_cases_and_finishes_every_case_without_cancelling_on_first_failure`, which is
    catalogued (row `test-support-shaping-evaluation-driver-rehearsal-test-py:t012`) and renamed in qb's ledger
    hunk;
  - `test_setup_fixture_excludes_every_guarded_paths_volatile_path`, the landed build.lock regression (not
    catalogued);
  - `test_turn_end_decision_advances_completes_and_fails_fast` (not catalogued).

qb's copies of these three files are a pre-82ac4351 port that overwrote build-reliability. Slice 3 therefore starts
from HEAD's files and ports named functions only. It never applies those qb or Zuj hunks as whole files.
