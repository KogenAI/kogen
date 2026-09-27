# Questions and choices

No open questions.

The Shaper approved these outcomes in `shaping-quality` revision 13 ("Approved.", 2026-09-26): directions 3, 5,
8, 11 and 36, the auditor profiles, and the Jev privacy allowlist. The split and every technical choice below were
made by the orchestrator under the Shaper's delegation (DIRECTION rules 43 and 46.5). [orig N] marks the original's
`## Assumed` item N, and [new] marks items that come with the split.

## Assumed

1. **The auditor is a separate `auditor` setting per route, outside the Build role matrix, with no helpers and
   never a fallback.** [orig: Settled, revision 10; direction 5] Reason: the Shaper: "Auditor is different than
   expert! … auditor should have a separate setting". Undo: none within the Shaper's rule.
2. **`--disable multi_agent` stays on the Codex auditor as a guard, not a speed claim.** [orig 20] Reason: an A/B
   probe (`evidence/probe-auditor-ab-2026-09-26.md`) shows no speed difference (n=1), and the flag enforces "the
   auditor has no helpers" at no cost. Undo: drop the flag.
3. **No hard time limit on the auditor. It measures itself with `date`.** [orig 28, superseding orig 21 and 26]
   Reason: the Shaper: "there shouldn't be hard limits for now, no killing auditors, shaping sessions etc. / but it
   should be written that they should manage themselves by running date at the start of their session and then
   measuring that throughout the session" (direction 36). The count bound (at most 2 runs per `HEAD`) stays. Undo:
   restore a per-run kill.
4. **The auditor runs at most twice per slug, `HEAD` and route. A launch failure does not count.** [orig: revision
   12 reshape brief; fix 5] Reason: the Shaper: "the auditor at most once per HEAD by default (the second run only
   when the first found blocking findings and the Draft changed)". Undo: a different bound in `auditor.ex`.
5. **Jev's layer deadline is 60 s in total, and each request keeps its 60 s timeout.** [orig 5] Reason: "Jev in
   seconds on every stop". Proving run 2 measured the gate at about 1 s. Undo: 180 s for the layer (revision 11's
   value; not a raise beyond it).
6. **`shp-one-build` is dropped from `settled.json`, and no `source` names a `.kogen/intents/` path.** [new]
   Reason: the entry reads "The Shaping audit (deterministic checks, Jev, auditor, Stop hook, Build gate) is one
   Intent and one Build". The Shaper removed the Build gate (direction 7), and this delegated split replaces "one
   Build". A gate citing it would answer the exact question this split settled, with a false decision. Splits stay
   product questions through `dir-1.17` and the gate's `product_ux` rule. A `source` path into the package moves
   when the package lands, so the entries cite the original by slug and id. The other 9 texts stay byte-equal to
   the calibration. Undo: restore the entry with a corrected text, and re-run the held-out calibration
   (`evidence/jev-routing-calibration/heldout_gate_v3.py`, copied and run with `python3 -B`, lesson 21).
7. **The tests compare the shipped Jev tables against byte copies under `test/support/shaping_audit/calibration/`,
   with pinned SHA-256s.** [new] Reason: the Candidate's tests read `.kogen/intents/approved/shaping-quality/…`,
   which is absent in a Candidate worktree (probe P1 failures 1 and 2) and moves on landing. Undo: none sensible.
8. **Outside a Shaping session, the auditor launches only with `--auditor`. Without it, the stored run is reused
   or the layer is `not-run` (not ready).** [new; the Candidate's `launch?` rule] Reason: an audit of seconds on
   demand, and a paid auditor only when asked. The Stop hook of slice 3 launches it at stops. Undo: launch by
   default when the bound allows.
9. **`gate_questions/3` and its CLI stay out until slice 3.** [new] Reason: their only caller is slice 3's
   `integrity.py` (no plumbing without a caller, direction 9). Undo: none needed.
10. **A route with no `auditor` entry yields a config with no `:auditor` key.** [new; fixes the Candidate's defect
    (1)] Reason: existing configs and fixtures must keep loading and comparing equal. `lifecycle_test.exs:637`
    refutes the key. Undo: none sensible.
11. **The report's `schema_version` becomes 2.** [new] Reason: the report now holds three layers, so a slice-1
    report is re-audited, not trusted. Undo: none needed.
12. **An out-of-vocabulary gate answer is re-asked once, and the second makes the layer `unavailable`.** [orig risk
    live-gate-and-codepaths; the Candidate's `ask_in_vocabulary`] Reason: in Build nasJwCPE, the real Jev answered
    the gate with `no_objection`, from `Kogen.Jev`'s objection set. `Kogen.Jev.valid_answer` stays strict. Undo: no
    re-ask.
13. **Slice 1's two audit test files switch to `Kogen.IsolatedCase`. Their tests that expect `ready` or exit 0 run
    with `--auditor` and the audit-only fakes.** [new, re-preflight] Reason: readiness needs every layer `ok`
    (approved), so a landed test that expects `ready` needs an auditor run. The unchanged adapters read
    `KOGEN_HARNESS` from the process environment (`lib/kogen/codex.ex:62`, `lib/kogen/claude_code.ex:179`), and
    `System.put_env/2` is safe only in an isolated VM. qb's task file was already isolated, and P1 passed. The
    alternatives would weaken nine tests to `not_ready` or rename them. Undo: read `KOGEN_HARNESS` from `main/2`'s
    env through a new adapter branch.
14. **The audit reads `KOGEN_ROLE`, `KOGEN_JEV_TRANSPORT` and `KOGEN_JEV_SECURITY` only from `main/2`'s env. The
    auditor launch drops `KOGEN_HARNESS_HOME`.** [new, re-preflight] Reason: the Developer's Build session exports
    `KOGEN_ROLE` and `KOGEN_HARNESS_HOME`, and two earlier Reviews found tests that depended on them (risk
    `build-session-environment`). A slice-1 call with `env: %{}` would otherwise let `Kogen.Jev` fall back to the
    real Keychain (`lib/kogen/jev.ex:524`). Undo: keep the inherited harness home in the auditor's environment.
15. **This slice's fixture packages live under `test/support/shaping_audit/packages/`, and `Fixture.add_draft!/3`
    gains `source:`.** [new, re-preflight] Reason: slice 1's A3 loads every directory under `drafts/`, reads its
    `intent.yaml` and runs `build/4`. The asking packages have no `scenarios.yaml`, and `flow/` is a directory of
    packages. Undo: extend A3's exclusion list instead.
16. **`main/2` takes `jev_deadline_ms:` (default 60 000).** [new, re-preflight] Reason: J9's deadline case needs a
    deadline shorter than a 60 s sleep. It is a duration beside the landed `:read` and `:io`, not a replaced layer.
    Undo: an environment variable.
17. **`recommendation-without-evidence` and `assumption-without-reason` are mechanical. A `fixed` disposition
    closes a finding only after a fix-check answer with `still_open: false`.** [new, re-preflight] Reason: both
    rules check whether a line is present, which is exact, and a `fixed` claim that Jev could not check must not
    pass. Undo: make both rules disputable.
18. **A Jev outage is reported as `layers.jev` `unavailable` plus one advisory `jev-unavailable` finding, scope
    `environment`.** [new, re-preflight; qb's shape] Reason: readiness already fails on the layer status, and the
    finding carries the reason into `report.md`, like slice 1's `repository-invalid`. Undo: drop the finding.
19. **The privacy allowlist includes a scenario's `given` and `when`, only in `clause-provider-only` and fix-check
    requests.** [new, Opus round 1] Reason: the byte-pinned `question-set-v1.json` (`clause-provider-only`, state
    `given`, `when`, `then_clauses`) and `fix-check-v1.json` (state `scenario {id, given, when, then, wrong_result,
    evidence}`) already send them, and both were calibrated that way. They are contract text from `scenarios.yaml`,
    the file the allowlist already draws from. Undo: drop the two fields, which changes calibrated wording and needs
    a new calibration.
20. **A `fixed` auditor finding is fix-checked against the scenario its disposition names.** [new, Opus round 1]
    Reason: auditor findings carry no scenario (the findings schema has label, summary, detail and paths only), and
    the fix-check was calibrated on (finding, scenario) pairs. The first `scenarios.yaml` id named in `<what
    changed>` is exact and costs the Shaper nothing. A `fixed` line naming no scenario gets no fix-check and stays
    open. Undo: add a `scenario` key to the auditor's findings schema.
21. **Dispositions are applied before anything reads a finding's open state.** [new, Opus round 1] Reason: slice
    1's B7 and C2 dispose a disputable deterministic finding and expect `ready`; the auditor gate must see it
    closed. The fix-check must see the `fixed` disposition, so auditor dispositions come before the Jev layer.
    Undo: none; the other order breaks two landed tests.

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
  3. `shaping-stop-hook`: the Stop hook on the Codex Shaper, the Shaping prompts, the Codex research helpers, the
     live evaluation and the smoke fixture. Paid: `live-shaping-quality` and `live-shaping-smoke` (Codex).
  4. `claude-shaping-under-hook`: the Stop hook, `AskUserQuestion` and the research and probe helpers on the Claude
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
| `front-loaded-questions` (hook decisions, prompts, Codex launch, integrity) | 3 | `stop-hook-decides-every-stop`, `shaping-flow-prompts-and-codex-launch`, `evaluation-judges-questions-and-audits` |
| `front-loaded-questions` (Claude launch: `AskUserQuestion` not denied) | 4 | `claude-shaper-runs-under-the-hook` |
| `auditor-setting` | 2 | `auditor-setting-and-launch` |
| `blind-auditor-layer` | 2 | `auditor-runs-and-findings` |
| `shaping-stop-hook` (decisions, script, Codex registration, live) | 3 | `stop-hook-decides-every-stop`, `shaping-flow-prompts-and-codex-launch` |
| `shaping-stop-hook` (Claude `--settings shaping-settings.json`) | 4 | `claude-shaper-runs-under-the-hook` |
| `research-helpers` (Codex `--search`, Codex helper descriptions) | 3 | `shaping-flow-prompts-and-codex-launch` |
| `research-helpers` (Claude `WebSearch`/`WebFetch`, worker Edit/Write) | 4 | `claude-shaper-helpers-research-and-probe` |
| `evaluation-fixture-excludes-build-lock` | 3 | `evaluation-answers-every-question` (the landed regression kept, unchanged) |
| `evaluation-answers-front-loaded-questions` | 3 | `evaluation-answers-every-question`, `evaluation-judges-questions-and-audits` |
| `smoke-fixture-without-auditor` | 3 | `smoke-fixture-without-auditor` |
| `claude-shaping-under-hook` | 4 | `live-shape-to-build-under-the-hook` |

The INTENT.md sections "Shaper direction" (directions 1-37) and "How Shaping must go" are carried whole into slice
3, whose prompts deliver them. Slices 1, 2 and 4 cite them.

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
- `priv/kogen/test-reliability-remediation.yaml`: no slice adds or deletes a catalogued row, and slice 3's one
  rename edits only `priv/kogen/test-reliability.yaml`.
- `test/kogen/lifecycle_test.exs`: it passes unchanged once a route without an `auditor` has no `:auditor` key
  (slice 2, which fixes the Candidate's defect (1)). It is a slice-2 preservation selector.
- `test/kogen/scenario_tracking_test.exs`: it has no auditor assertion at 3531023d. It is a slice-2 preservation
  selector.

### This slice

- Five scenarios, all offline. Paid targets: none. The real Codex auditor launch and real Jev answers are observed
  by slice 3's `live-shaping-quality`. A Claude auditor is observed by slice 4's `live-shape-to-build`. Earlier
  Shaping probes already ran the route auditor directly: Sol high 244-255 s, Opus high 169 s
  (`evidence/probe-auditor-profiles-2026-09-26.md`).
- Guarded paths: 22 entries, all within the original's (the ledger added at the re-preflight).
- Carried risks: advisory-calibration, jev-key-setup, privacy-boundary, auditor-detection-not-prevention,
  audit-time-budget, report-ownership (auditor records), live-gate-and-codepaths, and codex-route-attempt-qbozahf8
  defect (1). New at the re-preflight: build-session-environment and tracked-config-consumers.
- Candidate defects fixed here: `:auditor => nil` (P1 failure 5), tests reading `.kogen/intents/` (P1 failures 1
  and 2), and a re-serialised gate file.
- **Deterministic:** `plan/tools/validate.exs` at b775974b: `Intent.read` ok, `Contract.load` ok,
  `VerificationPlan.build` ok and `VerificationPolicy.preflight` :ok. Slice 1's landed `mix kogen.audit` on this
  Draft at b775974b: `ready`, no finding (`evidence/probe-candidate-at-b775974b/RESULT.md`).
- **Not run:** Sol and Opus readiness rounds, and a Jev clause audit.

### Re-preflight at b775974b (2026-09-27, orchestrator, delegated)

Slice 1 landed as 6b4376e9. failure-reports (e65392cf) and build-breakers (b775974b) also landed. `shaped_against`
moves from 3531023d to b775974ba8b87e723d07122cafa46c2e4395d165. Every citation was re-derived at b775974b against
the landed code. The probes are in `evidence/probe-candidate-at-b775974b/RESULT.md`.
- **Moved anchors:**
  - `Kogen.Build.assigned_config/2`: `lib/kogen/build.ex:1992` → `:2121`;
  - `normalize_clean_route/1`: `:230` → `:231`;
  - `normalize_role_route/1`: `:265` → `:266`;
  - `roles/0`: `:365` → `:366`.

  Unchanged: `Kogen.Harness.open/3` (`:43`) and `bindings/3` (`:64`), the `bind/1` and `open/3` functions of both
  adapters, `management_allowed!/1` (`codex.ex:380`, `claude_code.ex:476`), `lib/kogen/jev.ex` (no change since
  3531023d), `helper_description/1` and `pinned_smoke_config` (`driver.py:583-595`).
- **Landed slice-1 shapes the Draft now names:**
  - `main/2`'s `:env`, `:read` and `:io` options, the `<readiness>: <revision>` line (`shaping_audit.ex:103`)
    and the usage line (`:43`);
  - `layers` as `{"deterministic": {"status": "ok"}}` and the report's nine keys, which become twelve;
  - `Report.status/5`, which counts any other `schema_version` as `missing`;
  - `Finding`'s `@mechanical` and `open_blocking?/1`;
  - `Questions.parse/1`, which returns only `dispositions` (`not-a-defect`, key `reason`), and its extension;
  - `Fixture.repo!/1`, `add_draft!/3` and `config_yaml/0` (routes `codex` and `other`, with no auditor);
  - `Kogen.CompiledFixture.mix_task!/3`, which adds the cataloged Jev fakes unless the caller sets its own.
- **Findings fixed in the Draft:**
  1. `ledger-closure`: the Draft edits the catalogued `intent_test.exs` (20 rows) and `harness_role_test.exs` (1 row)
     without guarding `priv/kogen/test-reliability.yaml`. Slice 1's own audit blocks it (P4b). The file is now
     guarded, with no row change.
  2. **Nine landed tests would fail:**
     - A2, B3, B7, C2, C5, D1, D2, D6 and D7 expect `ready` or exit 0, but readiness now needs the jev and
       auditor layers;
     - D1 pins the nine keys, `schema_version` 1 and the one-layer map;
     - every call passes `env: %{}`, which would reach the real Keychain.

     Scenario `auditor-runs-and-findings` now lists each change with its new expectation (Assumed 13, 14).
  3. **A3 would crash on the new fixtures.** It loads every `drafts/*`. The packages move to `packages/`
     (Assumed 15).
  4. **Duplicate code:** qb `intent.ex` hunks 6 and 9 still apply but would duplicate slice 1's `optional_string/2`.
     They are excluded (CANDIDATE.md).
  5. **qb's test seams** (`:layers`, `:launcher`, `:manifest`, `:jev_transport`, `:jev_security`) are excluded.
     `jev_deadline_ms:` is the one new option (Assumed 16).
  6. **`fake_jev_audit`:** its default answer could be a gate option, and its log defaulted into the checkout. The
     default now raises no finding, and the log needs `FAKE_JEV_LOG_DIR`.
  7. **Build-session environment:** every `main/2` call passes an explicit env with the audit-only Jev fakes;
     every `mix_task!/3` call clears `KOGEN_ROLE` and `KOGEN_HARNESS_HOME`; the auditor launch drops
     `KOGEN_HARNESS_HOME`; S5 plants hostile inherited values (risk `build-session-environment`).
  8. **D7 matched `not_ready`:** it asserted `output =~ "ready"`, which `not_ready` also matches. It now asserts the
     exact line `ready: <revision>`.
  9. **Tests without exact results:** they now list them (F1-F7, R1-R14, G3-G7, J2-J3, J9-J11). R14
     (`--status --auditor`) is new.
- **Noted, not changed:** a fresh materialization has no Codex project selector, so the auditor uses the shared
  Codex login scope (`lib/kogen/codex/state.ex:11`). Slice 3's `live-shaping-quality` observes it (risk
  `baseline-and-anchors`).
- **Validation:** `plan/tools/validate.exs` gives `:ok` at b775974b. No `mix test` ran: no Candidate was ported
  onto the landed files.

### Audit: Opus round 1 at b775974b + fixes (2026-09-27, orchestrator, delegated)

Verdict: not ready (`scratchpad/sq2r/opus.md`). Every checked citation matched, `affected_paths` ⊆
`may_change_guarded_paths`, and every layer is offline. Six blocking findings, all fixed as the review proposed:
1. **Dispositions applied too late.** INTENT.md gains "Audit order": dispositions go on the deterministic findings
   before the auditor gate, and on the auditor findings before the gate routes them and the fix-check reads them.
   Only `aud-*` findings with a `fixed` disposition are fix-checked, each paired with the scenario its disposition
   names (Assumed 20, 21). The J runs now pass `--auditor`. J6's fixed pair is three-findings' finding 1 with
   jev-clauses' `fix-target`, and the unrelated pair is finding 2 with `unrelated-target`. B7 and C2 are listed
   with their unchanged `ready`/exit 0 expectations, and R1 covers the disputed-then-audited case.
2. **D7's compiled fixture had no prompt or tables.** `Fixture.repo!(compiled: true)` copies `auditor.md`,
   `questions-v1.json`, `question-gate-v1.json` and `settled.json` before the initial commit (inside
   `test/support/shaping_audit/**`). `compiled_fixture.exs` stays unedited.
3. **S5 could not observe its facts.** The fake auditor answers `auth status` (exit 0, no stdin read) and echoes
   the requested `--session-id`. On Codex, argv, stdin, environment and working directory come from the fake
   auditor's log. `KOGEN_PROJECT_ROOT`, `cwd`, the trusted-project arguments and the scope come from the managed
   trace. `test/support/managed_codex_fixture.py` is now guarded and gains only the `cwd` and `project_root`
   keys; no test compares whole trace lines (checked with grep at b775974b).
4. **Allowlist vs byte-pinned tables.** The allowlist now says each request's state holds exactly its table's
   fields, and it includes `given`/`when` for `clause-provider-only` and the fix-check (Assumed 19). J5 asserts
   that no other request carries them.
5. **G7 vs calibration.** A gate request holds exactly `gate` and `settled_by`, and `confirm` goes alone.
6. **Uncovered `then` clauses.** Each now has a test:
   - J14: advisory-only Jev with `--auditor` is `ready`;
   - J15: request digests and parsed answers, never bodies (`layers.jev.requests`/`answers`);
   - G9: `layers.jev.routes` with distributions, model and wording version, plus the package's `## Settled`
     appended as `package-<n>`;
   - R15: a missing setting is `unavailable` naming route `codex`, with no launch;
   - R16: the materialization is removed after ok, unavailable, rejected and launch-failure runs;
   - S8: the parser accepts auditor.md's example object.

Notes folded in:
- D6 merges `KOGEN_ROLE=shaper` into `audit_env!`.
- S6 uses `~r/managed roles cannot run setup/`.
- The CANDIDATE.md qb changes:
  - R6 `bound_reached: true` on the first run;
  - J6 `partly` keeps a finding open;
  - `fake_auditor` gains `git rev-parse HEAD`, the file list and `FAKE_AUDITOR_FAIL`;
  - `fake_jev_audit` gains a per-question default table and `<question id>@<match>` keys.
- First-try traps:
  - R2 compares canonical paths (`Kogen.ProjectScope.canonical/1`);
  - J1 builds its `.kogen/intents` needle at run time;
  - S2 uses route `codex` from `@valid_config`.
- SHA-256 literals recomputed with `shasum -a 256` on 2026-09-27:
  - `question-set-v1.json` `6057cdd1…9353ef`;
  - `fix-check-v1.json` `d71c560c…569690`;
  - `question-gate-v1.question.json` `18de817b…198446`.

  All match INTENT.md.

Scenario count stays 5 (tests: J 15, G 9, F 7, S 8, R 16), so no further split. **Not run:** `mix test` (no
Candidate is ported onto the landed files) and an Opus round 2.
- Opus round 2 at b775974b: ready; tidy-ups applied by the orchestrator (R-rejected wording, G6 clean copy, path count).
