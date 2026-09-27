# Questions and choices

No open questions.

The Shaper approved the outcomes of this slice in `shaping-quality` revision 13 ("Approved.", 2026-09-26). The
split and every technical choice below were made by the orchestrator under the Shaper's delegation (DIRECTION rules
43 and 46.5). Items marked [orig N] are carried from the original package's `## Assumed` item N, and items marked
[new] come with the split. Each item states its reason and how to undo it.

## Assumed

1. **`title-format` and `commit-subject-format` are mechanical deterministic checks.** [orig 3] `title` must be at
   most 50 characters, start uppercase and have no trailing period. `commit_subject` must be present, at most 72
   characters, start uppercase, have no trailing period and be a single line. Imperative mood stays prompt-only.
   Reason: the cbea.ms rules the Shaper named are exact except mood, and the check costs milliseconds. Undo: delete
   both rules and keep the prompt text (slice 3).
2. **`commit_subject` is a separate `intent.yaml` field, not a reuse of `title`.** [orig 14] Reason: the Shaper said
   "more chars can fit the message than should be normal for intent name … it can be (very) similar usually"
   (package direction 29). Undo: drop the field and commit `title` directly.
3. **A package without `commit_subject` is published with its `title`.** [orig 30] Reason: package direction 29
   sets this fallback. DIRECTION rule 44 targets removed paths, not this documented compatibility. Refusing such a
   package would also break every Build fixture that writes only `title` (`scripted_build_fixture.ex`,
   `workspace_fixture.ex`, `verification_cycle_fixture.ex`, `generic_project_fixture.ex`,
   `live_reviewer_rework_fixture.ex`), none of which is guarded here. Undo: refuse a package without the field,
   naming it, then guard and edit every writer listed above and select `live-reviewer-rework`.
4. **The Candidate hunks inside the package are the starting code, and no branch or stash is used.** [orig 8, as
   amended by the delegated re-preflights] Reason: direction 26 forbids Build inputs off `main` (branches, stashes,
   scratchpads). A diff kept in the package's `evidence/` is none of those. Probe P1 shows this slice's qb hunks
   pass their tests at 3531023d, and probe P3 shows they still apply and pass format, compile and credo at
   e65392cf. Undo: implement from scratch from the scenarios alone.
5. **No preload requirement.** [orig 9] Reason: since isolated-candidate-workspace (7ed41f66, still true at
   e65392cf), a Candidate compiles in its own worktree with its own `_build`, so the running controller never calls
   this Intent's edits to `verification_plan.ex`, `verification_policy.ex`, `build.ex`, `intent.ex` or `harness.ex`.
   Undo: if bind-controller-generation later brings back a shared-generation hazard, add a preload note naming these
   modules.
6. **Anchors are cited by function, with the line numbers re-derived at e65392cf.** [orig 11] Reason: a copied line
   number goes stale at the next move, and `finish_publication/4`'s call already moved from :2383 to :2606 and
   then to :2742. Undo:
   pin line numbers and re-verify them at every move.
7. **The generic late-load check and the preload default fix stay removed.** [orig 15] Reason: they no longer catch
   a real failure (see item 5), and the Shaper's rule is "no unnecessary checks". Undo: the same as item 5.
8. **A paid target that another scenario also selects is not over-broad.** [orig 17] Reason: the Shaper's example
   flags a target chosen "only for driver mechanics", and a shared run costs nothing more. Undo: drop the "no other
   scenario selects it" condition.
9. **Out-of-scope ROADMAP rows stay Non-goals, not deferred scope.** [orig 12] Examples: bind-controller-generation,
   login-scope keys, harness selection, route configuration and catalog semantics. Reason: direction 9 forbids
   unrequested splits and plumbing without a caller. Undo: pull one of these rows in explicitly, with the Shaper's
   approval.
10. **`ledger-closure` asks for the ledger to be guarded whenever an affected path holds catalogued tests.** [new]
    This resolves the original package's open Audit item ("ledger-closure still treats any affected catalogued test
    file as needing the ledger guarded, although at 82ac4351 body edits need no row change"). The audit cannot tell
    a body edit from a rename in code. Guarding the file costs nothing in a Build, and the message says so and
    states that body edits need no row change. Reason: an unguarded rename is a guard violation that ends a Build
    (the recurring miss this Intent exists to catch), while a spare guard line is harmless. Undo: fire only when a
    scenario sentence names a catalogued declaration with a rename or deletion word.
11. **`ledger-row-update-unstated` detects a row deletion or addition from one sentence, with whole words, and is
    disputable.** [new] The rule is written out in INTENT.md "Ledger rules". The candidates' substring test ("delet"
    or "add", and not "rename") fires on "address", "added" and almost every scenario. Reason: it is deterministic,
    it has negative controls (rename, body, "address"), and a false positive can be disputed. The original's
    mechanical set does not include this rule. Undo: make it mechanical, or remove the text detection and require
    both ledger files whenever either is guarded.
12. **`prior-failures` reads the real tracking-record shape.** [new] The Build id is the record's directory name,
    and the signature is the last failed attempt's `failure` text. The candidates read top-level `build_id` and
    `signature` keys that no real record has (verified against `.kogen/runtime/scenario-tracking/*/record.json` at
    3531023d). Reason: fixture-specific shortcuts are the failure lesson 27 names. Undo: none sensible.
13. **`paid-path-unproven` reads the target's catalog `owner` and its `prepare` paths.** [new] The original said
    "owner or driver path" without defining "driver". `prepare` is where the catalog names a target's driver
    (`test/support/shaping_evaluation/driver.py` for both shaping targets). Reason: exact, and read from the
    committed catalog. Undo: owner only.
14. **Report `schema_version` 1 has only the `deterministic` layer, and slice 2 raises it to 2.** [new] Reason: no
    plumbing without its caller (direction 9). The Jev and auditor layers land with their code, and an unknown
    schema already counts as `missing`, so a slice-1 report is re-audited after slice 2. Undo: ship all three layer
    keys now with a `not-implemented` status.
15. **`KOGEN_ROLE=auditor` is refused from this slice on, and `KOGEN_ROLE=shaper` runs normally until slice 3.**
    [new] Reason: the four refused roles are the approved contract, and refusing an environment value costs nothing.
    The Shaper case ("audits nothing inside a Shaping session") needs the Stop hook, which lands in slice 3. Undo:
    add the auditor refusal in slice 2.
16. **The README's "### Shaping audit" section grows slice by slice.** [new] This slice writes the command, the
    layout, readiness and "A report is never approval". Slice 2 adds Jev and the auditor, and slice 3 adds the Stop
    hook. Reason: the README states only what the product does at each landing. Undo: none needed.

17. **`prior-failures` keeps reading `record.json`, not the new `failure-report.json`.** [new, Opus round 1]
    Since e65392cf a stopped Build also writes `failure-report.json` (intent id, signature digest, category,
    same-signature count). Reason: every retained Build has a `record.json`, while Builds before e65392cf have no
    failure report; `attempts[].failure` is still a string (`lib/kogen/build.ex:2129`, `:2334`); one reader is
    simpler than two with a fallback. Undo: read `failure-report.json` when present and fall back to `record.json`.
18. **`repository-invalid` is any `VerificationPlan.load/1` error on the materialization, with the layer
    `unavailable`; qb's `require_no_extra_targets/2` is not taken.** [new, Opus round 1] Reason: qb's hunk added a
    Build admission refusal (a Build change nobody approved) and qb recognised the finding by its message text, so
    the Draft's own A6 (a catalog target with no Make rule) got no finding. `load/1` is exactly what Build admission
    runs. Undo: approve the extra-target refusal as its own Build scenario.
19. **Slice 1 writes its own `Kogen.ShapingAudit.Questions`, reading only `## Dispositions`.** [new, Opus round 1]
    Reason: the kept qb code calls `Questions`, and B7/C2 need dispositions, but qb's file carries slice 2's states
    and the asking gate and stores `text` where C2 asserts `reason`. Slice 2 extends this file. Undo: land qb's
    whole file here and move the asking-state tests with it.
20. **The two audit test files hold exactly the listed tests, and a label like `A1` is not part of a test name.**
    [new, Opus round 1] Reason: "start here, then add" kept qb tests that contradict this Draft (the removed ledger
    format, the extra-target case, the old record shape, a nested `mix test`). Names without labels survive a
    renumbering without a ledger edit. Undo: prefix names with the label.
21. **`priv/kogen/test-reliability.yaml` is guarded, with no row change expected.** [new, Opus round 1] Reason: this
    slice edits catalogued files (`intent_test.exs` rows t001-t020, `commit_provenance_test.exs` row t001), so its
    own `ledger-closure` rule requires the guard; Assumed 10 says the spare guard is harmless. Undo: none needed.

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
  The slices were split at develop 3531023d933419dee4adb618af9f7853c31eb9b0; this slice is re-baselined to e65392cf. Between b2073666 and 3531023d
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

- Five scenarios, all offline. Paid targets: none. Guarded paths: 14 entries, all within the original's
  `may_change_guarded_paths`.
- New against the original, from verification at 3531023d and e65392cf:
  - the ledger-by-name rules (Assumed 10 and 11);
  - the real-record `prior-failures` (Assumed 12);
  - the `prepare`-path reading of `paid-path-unproven` (Assumed 13);
  - fixtures `ledger-rename`, `ledger-both`, `ledger-body`, `paid-proven`, `paid-shared`, `stale-unavailable` and
    `no-subject`, as negative and positive controls.
- Candidate defects avoided here:
  - qb's `build.ex` lacks the publication subject: take Zuj hunk 2;
  - qb's ledger fixture and rule use the removed `maintained_sources` and `source_sha256` format;
  - qb's fixture still ships the deleted `scripts/check/refresh_test_reliability_sources.py`;
  - qb's `prior-failures` reads keys real records lack;
  - qb put `ledger-row-update-unstated` in the mechanical set;
  - cycle 1 of qbOzahf8 failed `mix format` on `verification_plan.ex`.
- **Deterministic:** `plan/tools/validate.exs` on this directory at 3531023d, re-run at e65392cf by the orchestrator: VerificationPolicy.preflight :ok: `Intent.read` ok, `Contract.load` ok,
  `VerificationPlan.build` ok and `VerificationPolicy.preflight` :ok (see the summary printed with the split).
- **Not run:** a Sol readiness round, a Jev clause audit, or this Intent's own audit (it does not exist yet).

### Opus slice-1 round 1 + fixes (2026-09-27, orchestrator, delegated)

Opus (`claude-opus-5-5`, plan mode, read-only) reviewed this package at develop e65392cf. Verdict: not ready, six
blocking findings. Each is fixed as Opus proposed:
1. **Slice 1 needed a module slice 2 owned.** The kept qb code called `Kogen.ShapingAudit.Questions` (`findings`,
   `state`, `entries`), whose file was slice 2's. Fixed: a new slice-1 `questions.ex` reads only `## Dispositions`
   (key `reason`, optional leading `- `, `not a defect` only; INTENT.md "Disputes", CANDIDATE.md). The
   `Questions.findings/state/entries` calls and the asking state are removed from the kept hunks. Slice 2's
   CANDIDATE.md and INTENT.md now say to extend this file (Assumed 19).
2. **The `verification_plan.ex` hunk was not purely additive.** Fixed: qb's `require_no_extra_targets/2` hunks are
   dropped; `repository-invalid` is any `VerificationPlan.load/1` error, not a substring match, with the layer
   `unavailable` (INTENT.md "Repository validity"). A6 now matches the rule, and also asserts that `load/1` still
   accepts an extra `live-*` Make rule (Assumed 18).
3. **Not re-baselined.** Fixed: `shaped_against` is e65392cf5d9265f0e0e9c8dae1e078ba4ddfb533 in intent.yaml,
   INTENT.md, scenarios.yaml, references.yaml and risks.yaml. `finish_publication/4` is cited at :2732 and its
   `commit_staged` call at :2742; the ledger paragraph at `scripts/check/README.md:221-226`. Probe P3
   (`evidence/probe-candidate-at-e65392cf/RESULT.md`) re-ran `git apply --cached --check` against a temporary
   index of e65392cf: identical to 3531023d (qb 164/166, Zuj 160/175, Zuj `build.ex` hunk 2 alone, and the trimmed
   `verification_plan.ex` hunk 1 applies). CANDIDATE.md is updated.
4. **The test list was open.** Fixed: the checks file holds exactly A1-A7, B1-B7 and C1-C6, the task file exactly
   D1-D8; the label is not part of the test name; every other qb test is removed, and the contradicting ones are
   named in INTENT.md "Tests and fixtures" and CANDIDATE.md (Assumed 20).
5. **D7's fixture was unspecified.** Fixed: `Fixture.repo!(compiled: true)` builds on
   `Kogen.CompiledFixture.create!/2`, then writes the Makefile, catalog and `.kogen/config.yaml` and commits. The
   fixture header now lists `.kogen/config.yaml` (routes `codex` and `other`), which D2 uses.
6. **Given/expected contradictions.** Fixed: `stale-disputed` cites only `cited_bytes`; A2 builds on a fresh
   materialization of the same HEAD and package; A3 excludes `invalid` (no scenario list) and `non-regular`; B2
   and INTENT.md state that deletion and addition words match whole-word, ignoring case.

The notes:
- **Ledger:** `priv/kogen/test-reliability.yaml` is guarded (Assumed 21); no row change is expected. E2 keeps the
  catalogued name "first and subsequent Builds record truthful automated provenance".
- **failure-reports:** `prior-failures` keeps `record.json` (Assumed 17).
- **Gate evidence:** probe P3b ran `scripts/check/offline.py`'s stages on the qb files at e65392cf: `mix format
  --check-formatted`, `mix compile --warnings-as-errors --force`, `mix credo --strict` (218 files, no issues) and
  the test-compile stage all exit 0. `mix test` on the audit, preservation, provenance and intent files: 133/135,
  with the two failures outside slice 1 (the codex `auditor` config, slice 2, and the unapplied README hunk).
- **Untested spec, now tested:** the multi-line `commit_subject` rule (C4, a two-line copy of complete) and the
  `prepare` and `proving-run` branches of `paid-path-unproven` (B5, with `Fixture.repo!(prepare: true)` and
  proving-run copies, each with its negative control). qb implements neither branch nor the line check;
  CANDIDATE.md says to add them.
- Opus slice-1 round 2: all 6 round-1 findings fixed; new blocker (KOGEN_ROLE inherited in role sessions) fixed by the orchestrator (env: %{} in main/2 calls, KOGEN_ROLE nil for D7); Dispositions split at ': not a defect'; citation nits fixed.
