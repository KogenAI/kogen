# Re-preflight probes at develop dece3e84 (2026-09-28, orchestrator, delegated)

HEAD: `dece3e84a25e7d3399a3c618b670caf399ea86e1` ("Continue interrupted Builds on rerun"), with slice 1
`shaping-audit-checks` (6b4376e9) and slice 2 `shaping-audit-jev-and-auditor` (3962af8b) landed. The repository
was read-only; every run used a scratch clone (`git clone` + `git checkout dece3e84`, `deps` symlinked, `_build`
copied) with `KOGEN_ROLE` and `KOGEN_HARNESS_HOME` unset. These are data, not code to run from the package.

## P0: Candidate applicability

Command: split each Candidate diff per file (and per hunk for every failing file), then
`GIT_INDEX_FILE=<tmp> git read-tree HEAD` and `git apply --check --cached <piece>` against the real repository.

- qb applies whole: `stop_hook.ex`, `stop_hook.sh`, `codex_environment_test.exs`, `live_shaping_evaluation_test.exs`,
  `shaping_audit_hook_test.exs`, `shaping_evaluation_test.exs`, `fake_mix`, `fast_auditor.ex`,
  `hook/{root,helper}-rollout.jsonl`, `driver.py`, `integrity.py`, `driver_rehearsal_test.py`,
  `driver_smoke_rehearsal_test.py`, `resume_transport.exp`, `shape_transport.exp`, `transport_test.py`.
- qb fails whole: `shaping_audit.ex`, `shaping_audit/report.ex`, `shaping_audit/jev_layer.ex`,
  `mix/tasks/kogen.audit.ex`, `shaping_audit_task_test.exs` ("already exists in index": slices 1-2 created them);
  `harness.ex`, `harness/codex.ex`, `codex/environment.ex`, `harness_role_test.exs`, `README.md` (patch fails).
  Per hunk: `harness.ex` hunk 2 (`role_context`/`tag_current_role`) OK, hunks 1 and 3 FAIL (slice 2 landed their
  auditor parts); `harness/codex.ex` hunk 2 (`shaper_args`) OK, hunk 1 FAIL (landed `launch_auditor/4`);
  `codex/environment.ex` hunks 2-4 OK, hunk 1 FAIL (landed auditor clause); `harness_role_test.exs` hunk 1 FAIL
  (landed); `README.md` FAIL.
- zuj applies: `kogen.shape.ex`, the three Shaping prompts, `free-text-panel/{opened,queued}.ansi`, `stop_hook.ex`,
  `stop_hook.sh`, `resume_transport.exp`, `transport_test.py`, `fake_mix`, `fast_auditor.ex`, the rollouts,
  `codex_environment_test.exs`, `live_shaping_evaluation_test.exs`, `shaping_audit_hook_test.exs`,
  `shaping_evaluation_test.exs`. zuj fails: `driver.py`, `integrity.py`, `driver_rehearsal_test.py`,
  `shape_transport.exp`, `README.md`, `shape_task_test.exs` (hunk 1 FAIL, hunk 2 OK), `harness_role_test.exs`
  (hunk 1 FAIL, hunk 2 OK), `harness.ex`, `harness/codex.ex` (hunk 3 FAIL), `codex/environment.ex` (hunk 1 FAIL),
  and the files slices 1-2 created.
- Since 3531023d, `git diff --stat 3531023d dece3e84` is empty for the three Shaping prompts,
  `lib/mix/tasks/kogen.shape.ex`, `test/support/shaping_evaluation/**`, `test/kogen/{shape_task,codex_environment,
  shaping_evaluation,live_shaping_evaluation,shaping_smoke_rehearsal,live_shaping_smoke,prepare}_test.exs`, the
  Makefile, `priv/kogen/verification_targets.yaml`, `.codex/**`, `priv/kogen/claude_code/**`, the ledger and the
  remediation file. It changes `.kogen/config.yaml` (one `auditor:` line per route), `lib/kogen/build/verification.ex`
  (login-rejected class), `README.md`, `lib/kogen/harness.ex`, `lib/kogen/harness/codex.ex`,
  `lib/kogen/codex/environment.ex` and `test/kogen/harness_role_test.exs` (slice 2).

Finding: qb's `shaping_audit_hook_test.exs` applies but cannot run: it passes `layers:` (`FakeMaterialization`,
`FakeDeterministic*`, `FakeAuditor*`, `FakeJevPassthrough`) to an `audit/2` that has no such option at HEAD.
qb's `driver_smoke_rehearsal_test.py` hunk 5 edits the catalogued wrong control.

## P3: the landed audit on the fixture packages the hook tests use

Command (scratch clone, `MIX_ENV=test mix run --no-start p3.exs`): `Code.require_file` of
`test/support/shaping_audit/fixture.ex`; for each case `Fixture.repo!/1` (or the flow checkout of
`shaping_audit_flow_test.exs`: `repo!(second_commit: false, working_tree: false, prior_failures: false)` plus a
committed `lib/demo.ex` and `test/kogen/demo_test.exs`), `Fixture.add_draft!/3`, `env = Fixture.audit_env!(root)`,
then `Kogen.ShapingAudit.main(argv, root: root, env: env, io: io)` and `Report.read/3`.

| Case | argv | exit / line | readiness | layers (det, jev, auditor) | open blocking ids |
|---|---|---|---|---|---|
| `complete`, FAKE_AUDITOR_MESSAGE=empty | `--auditor complete` | 0 `ready: …` | ready | ok, ok, ok | none |
| `complete` in `approved/` | `--auditor complete` | 0 `ready: …` | ready | ok, ok, ok | none |
| `complete`, route `other` | `--auditor --route other complete` | 1 `not_ready: …` | not_ready | ok, ok, unavailable "route other has no auditor setting" | none |
| `complete`, three-findings | `--auditor complete` | 1 | not_ready | ok, ok, ok (launched) | `aud-c60720-1`, `-2`, `-3` (route `shaper`, scope draft) |
| `complete`, no `--auditor` | `complete` | 1 | not_ready | ok, ok, not-run | none |
| `proof-defects` | `--auditor proof-defects` | 1 | not_ready | ok, ok, skipped | `unguarded-affected-path lib/unguarded.ex`, `proof-selector-missing test/gone_test.exs`, `proof-selector-missing test/stray_test.exs`, `unsupported-selector test/a_test.exs:3`, `unsupported-selector test/**`, `unsupported-selector /abs/x_test.exs`, `unsupported-selector ../x_test.exs`, `paid-reason-malformed not a valid reason`, `unknown-target live-extra` (all route nil) |
| flow `asking-no-answers` | `--auditor flow-demo` | 1 `asking: …` | asking | skipped, ok, skipped | none |
| flow `asking-technical`, FAKE_JEV_ANSWERS gate technical (set after `audit_env!/1`) | same | 1 | asking | skipped, ok, skipped | `technical-question-to-shaper 1`, `technical-question-to-shaper 2` (route `controller`, layer jev) |
| flow `asking-no-evidence` | same | 1 | asking | skipped, ok, skipped | `recommendation-without-evidence 1` |
| flow `asking-second-round` | same | 1 | asking | skipped, ok, skipped | none |
| flow `left-undecided` | same | 0 | ready | ok, ok, ok | none |
| flow `assumed-without-reason` | same | 1 | not_ready | ok, ok, skipped | `assumption-without-reason 1` |
| flow `not-ready` | same | 1 | not_ready | ok, ok, skipped | `unguarded-affected-path lib/demo.ex` |
| flow `ready` | same | 0 | ready | ok, ok, ok | none |

Flow `ready`'s `questions.sections`: Assumed 1 = "The button keeps its current size. Reason: the Shaper asked only
about colour. Undo: resize it in a follow-up Intent."; Left undecided 1 = "Whether to support dark mode.
Recommendation: defer, revisit after v1." (recommendation "defer, revisit after v1."); `not_audited_by_auditor` [].

Auditor bound (`complete`, three-findings, INTENT.md appended between runs): run 1 `bound_reached` false, 1 record;
run 2 `bound_reached` true, 2 records, the same three open ids; run 3 `bound_reached` true, still 2 records (no
launch). The flow packages need the flow checkout: on the plain `Fixture.repo!/1` every flow package also gets
`proof-selector-missing test/kogen/demo_test.exs`, and `FAKE_JEV_ANSWERS` set before `audit_env!/1` is deleted by it.

Report keys at HEAD: `findings`, `head`, `layers`, `not_audited_by_auditor`, `package`, `questions`, `readiness`,
`revision`, `route`, `schema_version`, `slug`, `state`.

## P4: the landed `mix kogen.audit` on this package

Command (scratch clone, package copied to `.kogen/intents/drafts/shaping-stop-hook/`, `KOGEN_ROLE` and
`KOGEN_HARNESS_HOME` unset): `mix kogen.audit --route codex shaping-stop-hook`, then `mix kogen.audit --status
--route codex shaping-stop-hook`.

- Before the re-preflight edits (default route `claude`): exit 1, `not_ready`, blocking
  `stale-anchor-baseline-unavailable` (that first copy was a history-less `git init` of HEAD's tree, so 3531023d was not a local commit) and
  `assumption-without-reason` 6, 8, 9, 11, 12, 13, 18.
- After them: exit 1, `not_ready: 6afad3ba31e64e4285e451faf4f8b435fe7c74fe16abf77ccd6e9d15264b28a5`; deterministic
  `ok`, jev `ok`, auditor `not-run` (no `--auditor`, no paid run); no blocking finding; three advisory Jev findings
  (questions.md). `--status`: `current`, exit 1.
