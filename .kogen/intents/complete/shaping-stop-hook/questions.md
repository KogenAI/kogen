# Questions and choices

No open questions.

The Shaper approved these outcomes in `shaping-quality` revision 13 ("Approved.", 2026-09-26). This slice carries
directions 1-37 and "How Shaping must go" whole (INTENT.md), and the original's `## Shaper answers` 1-25 are the
words those directions quote. The splits and every technical choice below were made by the orchestrator under the
Shaper's delegation (DIRECTION rules 43 and 46.5). [orig N] marks the original's `## Assumed` item N, and [new]
marks items that come with a split or a review.

## Assumed

1. **Questions go through the native picker (Codex `request_user_input`), or through stops with
   `## Ask the Shaper` entries.** [orig 1] Reason: the Shaper named a "pretooluse askuserquestion hook" for later,
   and proving run 6 showed the Codex root uses `request_user_input_async`, on by default in 0.156.1. The
   evaluation answers panels (`shaping-evaluation-live`). Undo: disable the Codex feature and return to stop
   questions.
2. **Complex means more than 8 scenarios, 2 or more selected paid targets, or more than 10 files under
   `evidence/`.** [orig 2] Reason: "Derived automatically" (the Shaper). Each part is countable. Undo: change the
   thresholds in `stop_hook.ex`.
3. **The Claude side lands in slice 5. Until then the Claude Shaper runs the new prompts without the hook.** [new]
   The Claude Shaper's hook (`--settings shaping-settings.json`), its helpers' `WebSearch`, `WebFetch`, `Edit` and
   `Write`, `fast_auditor.ex` and the `live-shape-to-build` probe need a real Claude session to prove. The Shaper's
   Kogen Claude login is revoked (lesson 24). Consequences until slice 5 lands: on Claude, "end your turn to
   re-audit" does not audit; a Claude Shaper worker still refuses Draft edits; `live-shape-to-build` is not
   re-proven, and no Build may select it before slice 5 (risk `claude-interim`). Reason: land every
   Codex-provable outcome now, while Claude waits. Undo: fold slice 5 in when the Claude login is back.
4. **The chain's clock resets at every allowed stop; its block count resets only on `ready`, `asking`,
   `environment` and `block-limit`.** [orig 4, restated after Opus round 1] Reason: the clock never counts the
   Shaper's thinking time, and a stalled or auditor-bound stop keeping the count means a chain that alternates
   blocks and stalls still reaches the 8-block escape (H4). An allowed stop records the chain it ends (H16). Undo:
   reset the count at every allowed stop.
5. **Fix 8 becomes "helpers investigate every supplied source, and gaps are asked within the window".** [orig 7]
   Reason: the root asks immediately and delegates research. Undo: the root reads every source before its first
   stop.
6. **A slug rename moves the directory first and then the slug, and tells the Shaper the new `mix kogen.shape`
   command.** [orig 18] Reason: direction 35; renaming the slug first made `mix kogen.shape` refuse with "draft
   intent.yaml slug does not match selected slug" and closed the session. Undo: remove the prompt sentence.
7. **The prompt asks only when a real product question is open.** [orig 24] Reason: in the case-fit prototype, an
   "ask within 60 s" wording made a complete request ask anyway. Undo: remove the condition.
8. **No hard time limits.** [orig 28] Reason: direction 36 ("there shouldn't be hard limits for now, no killing
   auditors, shaping sessions etc."). No auditor kill, no chain cutoff, no time-based skip. The count bound, Jev's
   60 s and the evaluation's 600 s (a test deadline) stay. Undo: restore revision 13's first dogfood version.
9. **The smoke fixture has no auditor, and its codex `worker` and `expert` helpers run on `gpt-6-luna` low.** [orig
   29, widened after Opus round 1 finding 5] Reason: the project's Sol-high auditor takes 244-255 s, most of the
   smoke's 300 s, and the project's `worker` (luna high) and `expert` (sol high) would make any helper the smoke
   starts slow. A fixture profile proves the launch path, not a model's judgement. Undo: pin a fast auditor instead,
   and restore the one-line pin.
10. **This Intent has no paid target.** [new, the 2026-09-28 split] Reason: every claim here is observable offline
    except the real TUI's hook behaviour, which the TUI probe settles (evidence/probe-codex-stop-hook-tui) and
    `shaping-evaluation-live`'s paid targets observe on 0.156.1 right after. D8 needs no target here: no live owner
    is edited. Undo: fold `shaping-evaluation-live` back in (the review's non-converging shape).
11. **Codex helpers get the Shaper-only descriptions and `--search`.** [orig 19, Codex half; direction 37] Reason:
    "Not just kogen-workers / thhhhhhhere are codex workers too". Undo: remove the Shaper clause of
    `helper_description`.
12. **`budget_ms` is 900 000, or 1 800 000 when complex.** [new; direction 7] Reason: 5 + 10 minutes, and 30 at
    most. It is recorded only and never decides. Undo: none needed.
13. **`mix kogen.audit --stop-hook` is dispatched before the landed role and lock refusals and always exits 0.**
    [new, re-preflight] Reason: the landed `run_command/8` exits 2 for `KOGEN_ROLE=developer` and a present
    `.kogen/build.lock`, which would leave Codex with no decision; the hook allows both itself. Undo: none sensible.
14. **The hook tests run the real landed layers through the audit-only fakes, not qb's `layers:` injection.** [new,
    re-preflight] Reason: slice 2 excluded that seam, so the landed `audit/2` has no `:layers`; probe P3 shows the
    fakes reach every decision with exact ids. Undo: add a layer seam to `audit/2` (plumbing no production caller
    uses, direction 9).
15. **The hook reads the landed `:clock` (a `DateTime`) twice per audited stop, never `System.system_time/1`, and
    decodes only UUIDv7 launch ids.** [new, re-preflight and Opus round 1] Reason: `main/2` documents `:clock` as a
    `DateTime`; qb's integer clock, its `launch_ms` from the system clock and its any-hex decoding disagreed with it
    and with a UUIDv4. Undo: an integer clock option.
16. **A truncated block reason keeps `report: <path>` as its last line, and the block-limit message reuses it.**
    [new, re-preflight] Reason: the scenario requires the report path last, and qb's byte cut dropped it and could
    split a UTF-8 character. Undo: none needed.
17. **Inside a Shaping session every manual form (`<slug>`, `--auditor`, `--status`) prints the same two status
    lines and exits 0 only when the newest hook report is ready.** [new, re-preflight] Reason: proving run 5 (a
    root that ran the audit itself spent 430 s). Undo: let `--status` run normally inside Shaping.
18. **Every test in this slice clears `KOGEN_ROLE` and `KOGEN_HARNESS_HOME` or sets them explicitly, including the
    smoke rehearsal and prepare runners.** [new, re-preflight and Opus round 1 finding 7] Reason: the Developer's
    Build session exports both, and earlier Reviews found tests that depended on them (risk
    `build-session-environment`). Undo: none sensible.
19. **P4 (the `KOGEN_SHAPING_*` variables) lives in `shape_task_test.exs` behind a test-written env-recording
    wrapper, not in the hook test and not by editing `fake_codex_shaper`.** [new, re-preflight] Reason: that file
    already owns the Codex Shape fixture helpers, adding a test to a catalogued file needs no ledger row, and the
    shared fake stays unchanged for `lifecycle_test.exs`. Undo: add env capture to `fake_codex_shaper`.
20. **`test/support/shaping_audit/fast_auditor.ex` is not added here.** [new, Opus round 1 finding 8] Reason: its
    only caller is slice 5's `live-shape-to-build` test, and `mix.exs` compiles no `test/support` path; direction 9.
    Undo: none; slice 5 adds it with its caller.
21. **`Kogen.ShapingAudit.error_text/1` is extracted from `report_error/2` and shared with the hook.** [new, Opus
    round 1 note] Reason: the hook's `{:error, reason}` message must be the text the task prints, and one function
    keeps them equal. Undo: duplicate the four texts in the hook.

## Audit

### The split (2026-09-27, orchestrator, delegated)

- **Why.** The approved `shaping-quality` (id `01a0d7a9-3642-720e-9809-e4962c3f1670`, revision 13) is one Intent
  with 13 scenarios and 3 paid targets. Its codex-route Build `qbOzahf8VYUfRIBFv61jH-_a` did not converge: 11
  check failures, with the core blockers unchanged over 4 cycles (risk `codex-route-attempt-qbozahf8`). The package
  was then parked to wait for the Claude route, but the Shaper's Kogen Claude login is revoked (lesson 24;
  DIRECTION rule 51). Lesson 27 says a large, API-specified Intent does not converge on the codex route: keep
  Intents there to 3-5 scenarios, enumerate the tests to write, and split at the first non-converging stop.
  DIRECTION rule 54 moved the codex Developer to high effort.
- **Authority.** DIRECTION rules 43 ("automatic shaping where just some unimportant details need to be reworked
  rather than UI/UX/DX") and 46.5 ("you gotta handle EVERYTHING") delegate technical reshaping to the orchestrator.
  Package direction 4 ("1 build") and DIRECTION 1.17 ("a necessary split is the human's decision") are the
  Shaper's own rules. This split is made under that delegation, is recorded here, and needs each slice's own
  (delegated) approval. The Shaper may overrule it on return: the original package is kept as a superseded
  reference in `.kogen/intents/drafts/shaping-quality/`.
- **Scope rule.** The split reshapes only the technical delivery and the landing order. Every UX/DX outcome the
  Shaper approved survives in exactly one slice (the map below). Nothing is dropped. No timeout is raised, and no
  check is weakened.
- **Landing order and what each slice proves:**
  1. `shaping-audit-checks`: `mix kogen.audit` with the deterministic checks, and `commit_subject`. Offline.
  2. `shaping-audit-jev-and-auditor`: the Jev contract questions, the question gate, the `questions.md` states, the
     auditor setting and launch, and the blind auditor layer. Offline.
  3. `shaping-stop-hook`: the Stop hook on the Codex Shaper, the Shaping prompts, the Codex research helpers and
     the smoke fixture pin. Offline (split again on 2026-09-28, below).
  4. `shaping-evaluation-live`: the live evaluation under the hook. Paid: `live-shaping-quality` and
     `live-shaping-smoke` (Codex).
  5. `claude-shaping-under-hook`: the Stop hook, `AskUserQuestion` and the research and probe helpers on the Claude
     Shaper, and the `live-shape-to-build` probe. Paid: `live-shape-to-build` (Claude). **It waits for the Shaper's
     Kogen Claude login.**

### Outcome map (original scenario → slice scenario)

| Original (revision 13) | Slice | Slice scenario(s) |
|---|---|---|
| `deterministic-checks` (proof, controller, catalog) | 1 | `audit-mirrors-build-admission` |
| `deterministic-checks` (ledger, live owner, paid) | 1 | `audit-ledger-live-and-paid-rules` |
| `deterministic-checks` (stale, disputes, history, titles, invalid) | 1 | `audit-anchors-titles-and-history` |
| `deterministic-checks` (`commit_subject` read and published) | 1 | `build-publishes-commit-subject` |
| `revision-report-and-command` | 1 (layout, refusals, `--status`), 2 (`--auditor`, auditor record path), 3 (inside a Shaping session) | `audit-command-and-report`; `auditor-runs-and-findings`; `stop-hook-decides-every-stop` |
| `jev-contract-questions` | 2 | `jev-contract-questions` |
| `question-gate` | 2 (routing, settled list), 3 (the seven default fixes in `shaping.md`) | `question-gate-routes-questions`; `shaping-flow-prompts-and-codex-launch` |
| `front-loaded-questions` (the `questions.md` states in the audit) | 2 | `questions-md-states` |
| `front-loaded-questions` (hook decisions, prompts, Codex launch) | 3 | `stop-hook-decides-every-stop`, `shaping-flow-prompts-and-codex-launch` |
| `front-loaded-questions` (integrity) | 4 | `evaluation-judges-questions-and-audits` |
| `front-loaded-questions` (Claude launch: `AskUserQuestion` not denied) | 5 | `claude-shaper-runs-under-the-hook` |
| `auditor-setting` | 2 | `auditor-setting-and-launch` |
| `blind-auditor-layer` | 2 | `auditor-runs-and-findings` |
| `shaping-stop-hook` (decisions, script, Codex registration) | 3 | `stop-hook-decides-every-stop`, `shaping-flow-prompts-and-codex-launch` |
| `shaping-stop-hook` (live, on fresh and resumed turns) | 4 | `evaluation-reads-hook-and-helper-rollouts`, `evaluation-answers-every-question` |
| `shaping-stop-hook` (Claude `--settings shaping-settings.json`) | 5 | `claude-shaper-runs-under-the-hook` |
| `research-helpers` (Codex `--search`, Codex helper descriptions) | 3 | `shaping-flow-prompts-and-codex-launch` |
| `research-helpers` (Claude `WebSearch`/`WebFetch`, worker Edit/Write) | 5 | `claude-shaper-helpers-research-and-probe` |
| `evaluation-fixture-excludes-build-lock` | 4 | `evaluation-answers-every-question` (the landed regression kept, unchanged) |
| `evaluation-answers-front-loaded-questions` | 4 | `evaluation-answers-every-question`, `evaluation-reads-hook-and-helper-rollouts`, `evaluation-judges-questions-and-audits` |
| `smoke-fixture-without-auditor` | 3 (fixture pin), 4 (the live smoke) | `smoke-fixture-without-auditor`; `smoke-runs-under-the-hook` |
| `claude-shaping-under-hook` | 5 | `live-shape-to-build-under-the-hook` |

The INTENT.md sections "Shaper direction" (directions 1-37) and "How Shaping must go" are carried whole into slice
3, whose prompts deliver them. Slices 1, 2, 4 and 5 cite them.

### Carried history

- **Approvals** (original `approval.md`, all historical for the slices):
  - the revision-7 driver batch approval (30b96fa0);
  - the revision-11 approval (363c20af);
  - the revision-12 approval (98ebcfb2), whose Build IEf3rtZ8 did nothing;
  - the revision-13 approval, "Approved." (7ed41f66, 2026-09-26);
  - the delegated re-baselines to 6dad9430, 82ac4351, 3ab70dce and b2073666;
  - the 2026-09-27 contract-change addendum (the smoke fixture, `ledger-row-update-unstated`, the title fallback);
  - the route addendum (`--route codex`, rule 51);
  - the parking note after qbOzahf8.
- **Builds of the original and their lessons:**
  - R9Oe4Fcp (the fixture inherited `build.lock`);
  - SQyTuy3C (front-loaded questions not answered);
  - eHsCjP0V;
  - IEf3rtZ8 (a restore from a branch; direction 26);
  - M2SJ9WX36UK8LsVX6ohzur4n (stopped for audit length);
  - 5l_rANAl (a free-text panel);
  - wTvOGC74 (the transport stop hang);
  - nasJwCPE (gate code paths, Jev vocabulary, a live reproduction in the Candidate);
  - qVFqG3da (a TMPDIR override);
  - Zuj-YgSGt (the csv-continuation helper profile, the technical question, queued panels);
  - qbOzahf8 (codex, non-converging).

  Each surviving lesson is a risk in the slice that needs it.
- **Baseline.** Original `baseline_history`:
  30b96fa0 → 363c20af → 9ff7af6e → 98ebcfb2 → 7ed41f66 → 6dad9430 → 82ac4351 → 3ab70dce → b2073666.
  The slices are shaped against develop 3531023d933419dee4adb618af9f7853c31eb9b0. Between b2073666 and 3531023d
  these landed: guard-violation-rework f1d176b0, test-flake-fixes 98f65b67, custody-standin-ready fa48e817,
  codex-developer-high bf28f2ca, custody-standin-timeout-ready 098e4561, kogen-ctx-index-and-search d9013413,
  kogen-ctx-symbols-and-map 8538b6a6 and kogen-ctx-mcp 3531023d. Over the original's guarded paths,
  `git diff b2073666 3531023d` changes:
  - `lib/kogen/build.ex`: guard rework. `finish_publication/4`'s `Kogen.Git.commit_staged/3` call moved from :2383
    to :2606, unchanged.
  - `.kogen/config.yaml` and the two tests `test/kogen/intent_test.exs` and
    `test/kogen/configuration_support_contract_test.exs`: the codex route's `developer` is now `effort: high`. This
    changes the context line of the qb `.kogen/config.yaml` hunk 2, which no longer applies as is.
  - `README.md`: the Rust prerequisite, the guard-rework paragraph, and a new "## Context index (`kogen-ctx`)"
    section just before "## Run the checks". This moves the insertion point of the qb README hunk, which no longer
    applies as is.
  - `priv/kogen/prompts/developer.md` and `reviewer.md` also changed. They are not guarded, and this Intent does
    not touch them.

  The ledger files are unchanged since b2073666.
- **Candidates.** `git apply --check` against a temporary index of 3531023d:
  - qbOzahf8 (`candidate-qbOzahf8-f4819c37-codex.diff`): 164 of 166 file diffs apply. Only `.kogen/config.yaml`
    (hunk 2 of 4) and `README.md` (its one hunk) fail.
  - ZujYgSGt (`candidate-ZujYgSGt-555d0af3.diff`): 160 of 175 apply. It fails on `.kogen/config.yaml`,
    `README.md`, `lib/kogen/build.ex` (hunk 1 only), `lib/kogen/harness.ex`, `lib/kogen/harness/{claude,codex}.ex`,
    `lib/kogen/intent.ex`, the ledger, `test/kogen/{configuration_support_contract,intent,shape_task}_test.exs`,
    and `test/support/shaping_evaluation/{driver.py,driver_rehearsal_test.py,integrity.py,shape_transport.exp}`.

  "Applies" is not "correct". Probes P1 and P2 (`evidence/probe-candidate-at-3531023d/RESULT.md` in slice 1) show
  which hunks pass their tests, and each slice's `evidence/CANDIDATE.md` lists its files.

### The original's guarded paths across the slices

Every original guarded path is carried by the slice that edits it. Three are carried by none, because no slice needs
to change them:
- `priv/kogen/test-reliability-remediation.yaml`: no slice adds or deletes a catalogued row, and slice 4's
  (`shaping-evaluation-live`) one rename edits only `priv/kogen/test-reliability.yaml`.
- `test/kogen/lifecycle_test.exs`: it passes unchanged once a route without an `auditor` has no `:auditor` key
  (slice 2, which fixes the Candidate's defect (1)). It is a slice-2 preservation selector.
- `test/kogen/scenario_tracking_test.exs`: it has no auditor assertion at 3531023d. It is a slice-2 preservation
  selector.


### Audit: re-preflight at HEAD dece3e84 (2026-09-28, orchestrator, delegated)

Slices 1 (6b4376e9) and 2 (3962af8b) landed, and so did the durable-builds split (e65392cf, b775974b, 99f93f60,
dece3e84), kogen-ctx and codex-developer-high. `shaped_against` moves from 3531023d to
dece3e84a25e7d3399a3c618b670caf399ea86e1. Every citation was re-derived against the landed code; the probes are in
`evidence/probe-preflight-dece3e84/RESULT.md` (P0 hunk applicability, P3 the landed audit on the fixture packages,
P4 below).
- **Unchanged anchors** (`git diff 3531023d dece3e84` is empty for these files): every `driver.py` citation in
  `intent.yaml`'s note, `parser_code_paths` (`:695-712`), `resolved_codex_route` (`:282`), `shape_transport.exp:67`,
  `transport_test.py:77-80`, `driver_smoke_rehearsal_test.py:271-274`, `prepare_test.exs:189`, `kogen.shape.ex`,
  the three Shaping prompts, the catalog, the Makefile, `.codex/**`, `priv/kogen/claude_code/**`, the ledger and
  `test_reliability_catalog.ex:36`.
- **New or moved anchors now cited:** `shaper_args/3` `codex.ex:265-267`, `auditor_args/2` `:216`,
  `exec_shaper/4` `:257-260`; `launch_auditor/4` `harness.ex:359-361`; `helper_description/1`
  `environment.ex:463-473`, `config_args/5` `:426`; `JevLayer.run/2` `jev_layer.ex:54-69` and its helpers;
  `Kogen.Intent.auditor_config/1` `intent.ex:410`, `mint_uuid7/0` `:667`; `prepare_class/2`
  `verification.ex:528-530`; `README.md:990-992`, `:1018-1019`, `:1030-1031`; `.kogen/config.yaml:18` (the codex
  auditor line).
- **The landed interface the hook now calls** (INTENT.md "The landed audit interface this slice calls"): argv
  `--route`/`--auditor`/`--status`, exit 0/1/2, refused roles and the lock, `:env`/`:read`/`:clock`/`:io`/
  `:jev_deadline_ms`, report schema 2 and its twelve keys, readiness `asking`/`ready`/`not_ready`, the layer
  statuses, `Finding.open_blocking?/1`, the auditor's `bound_reached`, `Report.write/3`, `runtime_dir/2` and
  `latest_revision/2` (which already reads `hook-state.json`'s `last_revision`).
- **Findings fixed in the Draft:**
  1. qb's `shaping_audit_hook_test.exs` injects `layers:` fakes the landed `audit/2` does not accept, and never
     clears `KOGEN_HARNESS_HOME`. The hook tests are rewritten on the landed fakes with probe P3's exact results
     (H1-H28; Assumed 20).
  2. qb's StopHook assumed an integer `:clock`; the landed option is a `DateTime`. It decoded any hex as a
     UUIDv7, and its truncation dropped the `report:` line (Assumed 21, 22).
  3. `--stop-hook` must be dispatched before the landed role and lock refusals, or a developer role or the lock
     exits 2 with no decision (Assumed 19, H9, H10, H28).
  4. Existing expectations that change are now named with their new expectation: the landed task test "an
     approved-only package and the Shaper role run normally" (renamed, Shaper half moved to H26), `README.md:1018-1019`
     and `:1030-1031` (H27), `driver_smoke_rehearsal_test.py`'s pin test (K1), the live owner t001 (V11), and both
     live owners' env lists. `priv/kogen/test-reliability.yaml` stays guarded; only t001's `declaration` changes.
  5. CANDIDATE.md was wrong in three places: `harness_role_test.exs` has no qb Shaper test (the P2 source is zuj
     hunk 1, ported by hand); qb `report.ex` has nothing the landed file lacks; qb `driver_smoke_rehearsal_test.py`
     hunk 5 edits a catalogued wrong control and is refused.
  6. The catalog also pins `Kogen.ShapingDraftAudit.audit!` and four fixture names; they are now in "Keep unchanged"
     and risk `self-hosting`.
  7. Build-session environment: every test and fixture that runs the audit, the hook, `stop_hook.sh`,
     `mix kogen.shape` or a Python evaluation process clears `KOGEN_ROLE` and `KOGEN_HARNESS_HOME` or sets them
     explicitly, and `driver.py` gains `child_environment()` (Assumed 24, risk `build-session-environment`, V12).
  8. Seven `## Assumed` entries (6, 8, 9, 11, 12, 13, 18) had no `Reason:`; the landed audit blocks that
     (`assumption-without-reason`).
  9. Every test now states exact results (ids, messages, byte counts, exit codes). P4 moves to `shape_task_test.exs`
     behind an env-recording wrapper (Assumed 25).
- **Paid targets.** `live-shaping-quality` and `live-shaping-smoke` run on the codex route in the controller's paid
  verification. Nothing in them needs Claude: the driver pins the one `harness: codex` route, `--prepare` checks only
  the Codex scope and toolchain, and the hook's auditor is that route's Codex auditor (Jev reads `dev.kogen.jev`).
  Each `paid_reason` now says so.
- **P4: the landed `mix kogen.audit` on this package.** In the scratch clone of dece3e84 (package copied to
  `.kogen/intents/drafts/shaping-stop-hook/`, `KOGEN_ROLE` and `KOGEN_HARNESS_HOME` unset), `mix kogen.audit --route
  codex shaping-stop-hook` exits 1 with `not_ready: 6afad3ba31e64e4285e451faf4f8b435fe7c74fe16abf77ccd6e9d15264b28a5`
  (the revision before this note). Layers: deterministic `ok`, jev `ok`, auditor `not-run` ("no prior auditor run to
  reuse, and launch is disabled": no `--auditor`, so no paid Sol run). No blocking finding. Three advisory Jev
  findings, recorded and not changed: `jev-request-too-large shaping-flow-prompts-and-codex-launch-clauses` (81 515
  bytes; that scenario's contract is the full prompt-passage list, which the Shaper's directions require);
  `then-without-described-proof evaluation-answers-every-question-c4` (queued questions: V6's
  `test_shape_answers_each_queued_panel_question_individually_and_records_it` and its resume twin prove it); and
  `hard-rule-effort-lowered evaluation-answers-every-question-c8` (the fixture's `gpt-6-luna` low helpers, a
  deliberate fixture profile, Assumed 16). `mix kogen.audit --status --route codex shaping-stop-hook` prints
  `current` and exits 1 (not ready). The first run, on the unedited package in a history-less copy of HEAD's tree (default route `claude`), was
  `not_ready` with 8 blocking findings: `stale-anchor-baseline-unavailable` and `assumption-without-reason` 6, 8, 9,
  11, 12, 13 and 18, all fixed above.
- **Validation:** `plan/tools/validate.exs` gives `Intent.read` :ok, `Contract.load` ok, `VerificationPlan.build`
  ok (targets `check`, `live-shaping-smoke`, `live-shaping-quality`) and `VerificationPolicy.preflight` :ok.

### Audit: Opus round 1 at dece3e84 (2026-09-28, orchestrator, delegated)

An Opus 5.5 review of the single slice-3 Draft at `dece3e84` (read-only, every file including `evidence/`) returned
"not ready". It found the Stop-hook unit tests (H1-H28) sound and the evaluation port and the two paid targets not
ready. Its nine blocking findings, and where each is fixed:

1. **The port list missed code the live cases need** (helper rollouts replaying the parent's `session_meta` and
   turns, the `scout` mapping, `all_owned_terminal`, integrity's `validate_native` filter, the native-panel skip in
   `ordered_turn_bindings`, V7's `running_helpers`/`helper_terminal`/`HELPER_STOP_MARGIN_SECONDS`, the resume argv
   8-11 helpers and `resume_exact`). Fixed in `shaping-evaluation-live`: every qb function is named with its
   source lines, and the resume argv is made strict (an empty Intent id fails the resume) and sets
   `KOGEN_ROLE=shaper`, which the review had not noticed: `managed_resume.py` drops `KOGEN_ROLE` when the outer
   process has none, so every resumed stop would have been allowed unaudited.
2. **Taking qb's `shaping_evaluation_test.exs` would drop three tests, the heavy-rehearsal split and add a
   contradicting assertion.** Fixed in `shaping-evaluation-live`: HEAD's file is kept whole and tests are added.
3. **Both live runs would talk to the fake Jev** (`isolated_case.ex:378-385,440`). Fixed in
   `shaping-evaluation-live`: both live owners pass `real_jev_env()` (`KOGEN_JEV_TRANSPORT` and
   `KOGEN_JEV_SECURITY` removed) with the two Build variables removed.
4. **The gate command contradicted risk `live-gate-and-codepaths`.** Fixed in `shaping-evaluation-live`: a bare
   `elixir -pa <path>… -e 'Kogen.ShapingAudit.JevLayer.gate_questions_main()'` run from the project root (the
   JevLayer tables are read relative to the cwd, `jev_layer.ex:28-30,45`).
5. **The smoke's assertions did not allow native panels, and the 300 s fit was unproven.** Fixed in
   `shaping-evaluation-live`: `SMOKE_REQUEST` forbids helpers and the question tool (the smoke keeps exactly one
   reply and one terminal binding); in this Intent the smoke fixture pins every codex helper to `gpt-6-luna` low
   and drops the auditor.
6. **The generic-answer rule broke the pinned `missing_answer` wrong control.** Fixed in
   `shaping-evaluation-live`: `drive()` gains `generic_answers` (default true; `run_smoke` passes false), so the
   smoke never appends a generic answer and the control, its fake and its "TurnEndFailFast" assertion stay
   byte-identical and catalogued. qb's hunk 5 (and hunks 2-3) are refused.
7. **The environment rule was not met by "unchanged" files.** Fixed: in this Intent
   `shaping_smoke_rehearsal_test.exs:15` and `prepare_test.exs:150/163/196/238` (K4, K5); in
   `shaping-evaluation-live` `child_environment()` at every `driver.py` spawn, including `:938`, `:1489` and
   `:1506`.
8. **`fast_auditor.ex` had no caller.** Removed from this Intent; slice 5 adds it with its caller.
9. **How a TUI Stop-hook block appears in the rollout was never probed.** Probed
   (`evidence/probe-codex-stop-hook-tui/RESULT.md`), below.

Its notes are fixed here: CANDIDATE.md lists all twelve `stop_hook.ex` adaptations (`chain_ms` at allowed stops,
the block-limit text, the summary format, the `{:error, reason}` text through a new `error_text/1`, `launch_ms`
from the clock); INTENT.md "The chain" states the per-kind state, so "resets at every allowed stop" means the
clock and H4's kept count is consistent; `flow_checkout!/0` is copied into the hook test. In
`shaping-evaluation-live`: row t001's `public_outcome` is updated with its `declaration`.

**The split.** The review's verdict separates cleanly: everything that needs no live run (this Intent, three
scenarios, no paid target) and the evaluation with both paid targets (`shaping-evaluation-live`, four scenarios).
This follows lesson 27 (keep codex-route Intents to 3-5 scenarios; split at the first non-converging stop) and was
made under the same delegation as the first split. This Intent lands first; `shaping-evaluation-live` lands next
(risk `evaluation-lands-next`).

**The probe (finding 9).** The plain `codex` CLI 0.157.1 with the operator's own default login, copied into a
private `CODEX_HOME` under the scratch `probe/` (never `~/.codex`, never Kogen's managed runtime, scopes or Keychain
items), Kogen's `@common_flags`, and a stub `-c hooks.Stop` that blocks once per turn. On a fresh TUI turn and on a
`codex resume` turn: the block continues the **same `turn_id`**, with no new `turn_context` and no
`task_complete` in between; each turn has **exactly one `task_complete`**, after the final allowed stop; the block
reason is a `response_item` `message` with `role: "user"` and text `<hook_prompt hook_run_id="stop:0:/&lt;session-flags&gt;/config.toml">…</hook_prompt>`
bound to the same turn, plus an `item_completed` `HookPrompt` event. Consequences: `drive`'s "first
`task_complete` ends the turn" holds; HEAD's `ordered_turn_bindings` would reject every blocked turn ("native user
intervenes before completion"), so `shaping-evaluation-live` skips a same-turn `<hook_prompt ` user message and
tests it on this rollout. A second run (`codex exec`, one plain `spawn_agent` helper, a logging hook) showed the helper's rollout has one
`session_meta` and only its own turns (no parent replay), `agent_role: null` on the root's profile, and that the
helper's turn end did **not** fire the Stop hook (one payload, the root's). Limits: 0.157.1, not the managed 0.156.1; n = 1 per phase; the forked-helper replay
shape is qb's 0.156.1 observation, not re-observed.

### Audit: Opus round on the split (2026-09-28, orchestrator, delegated)

An Opus 5.5 review of this slice after the split (read-only, at `dece3e84`) returned "not ready". It found two
blocking findings with one cause, and several notes. H1-H28 and P2-P5 were otherwise sound. Its checked-correct
list covers the other anchors, the `stop_hook.ex` changes against qb, H3/H7/H14/H16/H17, K1's lines, the env
sites of `prepare_test.exs`, and `affected_paths` within `may_change_guarded_paths`.

1. **The two catalogued smoke controls, K3 and K4 would fail under the new `pinned_smoke_config`.** The
   rehearsal's own synthetic project (`driver_smoke_rehearsal_test.py` `setUp`, `:73-76`) has a `codex-fake`
   route with no `auditor:` line and no helpers. `run_smoke()` calls `smoke_files()` first. So the new refusal
   "smoke: the codex route has no auditor entry to remove" fires in both controls, and `check` stops. The Draft
   had claimed "bodies and fakes unchanged".
   **Fixed:** editing `setUp` is now allowed, with exact text. In its `codex-fake` route, after the `shaping:`
   line, it gains exactly `    auditor:   {model: fake-model, effort: high}`, `    helpers:` and flow-map
   `scout` (low), `worker` (high) and `expert` (high) lines on `fake-model`, and nothing else. The two
   catalogued controls keep their names and bodies, and so does the fake's scripted Draft. The following were
   updated to match: scenario `smoke-fixture-without-auditor` (given, then, wrong result, K4), INTENT.md
   "Existing files…" and "Smoke fixture", risk `self-hosting`, and CANDIDATE.md.
2. **K3 could not exit 0.** The rehearsal project's `.gitignore` is only `.kogen/intents/drafts/`. The hook
   files K3 plants are therefore untracked and not ignored, so `baseline_unchanged` and the source identity
   differ, and `run_smoke` returns 1. "Ignored by `.gitignore`" was true of the real repository only.
   **Fixed:** the same `setUp` change makes the `.gitignore` text `.kogen/intents/drafts/\n.kogen/runtime/\n`,
   and the scenario's claim now names both files. K3 also states the two resets a second `run_smoke()` in one
   `setUp` needs: `<runtime>/runs` and the sessions directory.

**Probe** (`evidence/probe-smoke-rehearsal-setup/RESULT.md`). HEAD's `driver.py` was run with the new
`pinned_smoke_config` written from the Draft; qb's whole-file driver belongs to `shaping-evaluation-live`.
- With HEAD's `setUp`, both catalogued controls raise the auditor refusal (finding 1 reproduced).
- With the five route lines, both controls pass, and K3 exits 1 with `baseline_unchanged` false (finding 2
  reproduced).
- With `.kogen/runtime/` also ignored, all five tests pass on four runs: both catalogued controls, K1 (exact
  diff and both refusals on the tracked config), K3 and the invalid-manifest control.
- Not run: the `.exs` wrapper (K4) and `check`.

Notes, fixed:
- `flow_checkout!/0` is at `shaping_audit_flow_test.exs:56-64`; the INTENT.md, scenarios.yaml and intent.yaml
  citations now say so.
- **An `error` decision is never cached.** qb's `log_and_return/4` cleared the cache only for a block, so an
  error was stored under the environment's skip key, and `stop_hook.sh` would have replayed it on an unchanged
  package. Chosen: after an `error` stop, `hook-state.json` `skip_key` and `decision` are null, and the next
  stop re-audits. This is CANDIDATE.md adaptation 13, and INTENT.md's `stop_hook.sh` step 5, "The chain" and the
  `error` decision now say it. H13 proves it: a `ready` stop, then an `error` stop that nulls both fields, and
  `stop_hook.sh` with a null decision under its own logged key starts the fake mix again. "Caches an error"
  joined the wrong results.
- **P1 says "insert these exact sentences" and lists the exact substrings.**
  - Items 1, 2, 4, 5 and 6 of the Prompts list, plus "A probe that launches a provider in a disposable directory
    is not a verification gate.", are inserted word for word. They are the six sentences zuj's `shaping.md` lacks.
  - P1 asserts 42 numbered substrings on `shaping.md` compacted as t003 already does. They are checked in the
    probe: 36 are in zuj's text and 6 are to insert.
  - t003's six existing assertions are also present in zuj's text.
- **H27 compacts whitespace before its contains and refutes.** `README.md:1018-1019` splits the refuted
  sentence across two lines.

### This slice (after the 2026-09-28 split)

- Three scenarios, no paid target: `stop-hook-decides-every-stop` (H1-H28), `shaping-flow-prompts-and-codex-launch`
  (P1-P5) and `smoke-fixture-without-auditor` (K1-K5). Guarded paths: 22 entries, all within the original's.
- `priv/kogen/test-reliability.yaml` is guarded and byte-identical: this slice adds tests to or extends bodies in
  the catalogued `shape_task_test.exs`, `harness_role_test.exs` and `codex_environment_test.exs`, which the landed
  `ledger-closure` rule accepts with the ledger guarded and no row change. No catalogued test is renamed.
- Moved to `shaping-evaluation-live`: the evaluation scenarios (`evaluation-answers-every-question`,
  `evaluation-judges-questions-and-audits`), the live half of the smoke, `jev_layer.ex`'s `gate_questions*`
  (their caller is `integrity.py`), both live owners, the ledger row t001, and both paid targets.

### Validation and the landed audit (2026-09-28)

- `plan/tools/validate.exs` from the repository at dece3e84: `Intent.read` :ok, `Contract.load` ok,
  `VerificationPlan.build` ok (targets `check`), `VerificationPolicy.preflight` :ok.
- The landed `mix kogen.audit --route codex shaping-stop-hook` in the scratch clone of dece3e84 (`sq3/probe/clone`, package
  copied to `.kogen/intents/drafts/shaping-stop-hook/`, `KOGEN_ROLE` and `KOGEN_HARNESS_HOME` unset; script
  `sq3/probe/pkg-audit.sh`): exit 1, `not_ready: d91248e933eb6da7bbc4dc18016ae87048e93e3c07990217875c998a3ec6b412` (the revision before this note). Layers: deterministic `ok`,
  jev `ok`, auditor `not-run` (no `--auditor`, so no paid Sol run). **No blocking finding.** The Jev layer ran on the
  offline fakes (`KOGEN_JEV_TRANSPORT=test/support/shaping_audit/fake_jev_audit`, `KOGEN_JEV_SECURITY=
  test/support/fake_security`) because this reshape may not read Kogen's `dev.kogen.jev` Keychain item; its
  advisories (three `non-goal-leakage` naming the first non-goal for each scenario, and `jev-request-too-large shaping-flow-prompts-and-codex-launch-clauses` (81 515 bytes: the full prompt-passage list the Shaper's directions require)) are the fake's canned answers, not real Jev routing, so the real Jev layer is still to run
  (the next Shaping session's hook, or the orchestrator's audit with the Keychain available).
- Not run: a Sol readiness round on the split packages. The Opus round on this slice is above.
