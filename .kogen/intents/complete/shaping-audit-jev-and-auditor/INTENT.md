# Add Jev and auditor layers to the audit

Slice 2 of 4, split on 2026-09-27 from the approved `shaping-quality` Intent (id
`01a0d7a9-3642-720e-9809-e4962c3f1670`, revision 13; kept as a superseded reference
in `.kogen/intents/drafts/shaping-quality/`). Landing order:

1. `shaping-audit-checks`: `mix kogen.audit` and the deterministic checks;
   `commit_subject`. It must land first.
2. **this Intent**: Jev contract questions, the question gate, the `questions.md`
   states, the auditor setting and launch, and the blind auditor layer;
3. `shaping-stop-hook`: the Stop hook on the Codex Shaper, the Shaping prompts and
   the live evaluation;
4. `claude-shaping-under-hook`: the Claude Shaper under the hook (waits for the
   Claude login).

Shaped against develop `b775974ba8b87e723d07122cafa46c2e4395d165`. Slice 1
landed as `6b4376e9` (`.kogen/intents/complete/shaping-audit-checks/`). This
slice extends its landed `Kogen.ShapingAudit`, deterministic layer, report,
`questions.ex` and `mix kogen.audit`, and changes nine of its tests (risk
`builds-on-slice-1`). Build route: `codex`. Every proof is offline.

## What the Shaper gets from this slice

The Shaper's direction 3 is carried whole: "1. deterministic scripts/checks 2. jev
3. auditor (adversarial in case of 2 routes; if the route is codex, then auditor
will be sol high, if it's claude it's gonna be opus high; if it's claude with codex
adversary then sol high, etc.)". Direction 5 is also carried: "Auditor is different
than expert! Don't combine their prompts in any case! And auditor should have a
separate setting."

- **Jev in the audit.** 14 advisory contract questions plus the fix-check run on
  every audit, in seconds. The question gate routes each `## Ask the Shaper`
  entry and each auditor finding: to a settled decision (cite), to the
  Controller (technical), or to the Shaper (product). Jev reads its key only from
  the Keychain item `dev.kogen.jev`. It sends only the privacy allowlist. Its
  answers never make a report ready or not ready by themselves; an outage makes
  the layer `unavailable`.
- **`questions.md` states.** A package that is asking the Shaper (any open
  `## Ask the Shaper` entry) runs only the question checks:
  - a missing `scenarios.yaml` is not reported;
  - a technical question is blocked with "decide it and record it under
    ## Settled";
  - a question with no `Recommendation:` or no `Evidence:` is blocked.

  A second round of questions is allowed like the first. `## Left undecided`
  never blocks and is never moved. An `## Assumed` entry without `Reason:` or
  `Undo:` is blocked. The report lists every `## Assumed` and `## Left undecided`
  entry with its recommendation.
- **A blind auditor on its own setting.** `.kogen/config.yaml` gains one
  `auditor` entry per route:

  | Route | Auditor |
  |---|---|
  | `claude` | Claude Code `claude-opus-5-5` high |
  | `codex` | Codex `gpt-6-sol` high |
  | `claude-dominant-adversarial-codex` | Codex `gpt-6-sol` high |
  | `codex-dominant-adversarial-claude` | Claude Code `claude-opus-5-5` high |

  It never falls back to the Expert or any other role. It shares nothing with the
  Expert: no setting, no prompt, no helpers. It runs once per `HEAD` by default,
  and a second time only when the first run found something and the Draft has
  changed. It runs read-only, in a clone of `HEAD` plus the package, with no
  deadline: nothing kills it (direction 36), and its brief tells it to run `date`
  first and answer within about 4 minutes. `mix kogen.audit --auditor <slug>`
  launches a run when the bound allows. Without `--auditor`, the audit reuses the
  stored run of the same revision, `HEAD` and route. The Stop hook of slice 3
  launches it at stops.

How Builds start, the Build role matrix (`Kogen.Intent.roles/0`, the frozen
`role_assignment`, `Kogen.Build.assigned_config/2`) and `mix kogen.shape`'s
readiness list all stay unchanged.

## Starting point (exact)

The Candidate files are in `evidence/candidate-*-slice.diff`. `evidence/CANDIDATE.md` says, file by file and hunk by
hunk, what applies at `b775974b` (`evidence/probe-candidate-at-b775974b/`) and what to take. Probe P1
(`evidence/probe-candidate-at-3531023d-RESULT.md`) ran the qb Candidate at `3531023d` with qb's own slice-1 files:
its Jev, question-gate, auditor, harness-role, config-contract and Codex-environment tests passed, except for the
defects below. Take the qb hunks for:
- `lib/kogen/jev.ex`: `Kogen.Jev.ask/3`, keeping the full distributions and validating option ids;
- `lib/kogen/shaping_audit/{jev_layer,auditor}.ex` (new files);
- `priv/kogen/prompts/auditor.md`;
- the harness adapters' `launch_auditor/4`;
- `Kogen.Harness.open_auditor/2` and `launch_auditor/4`;
- `Kogen.Intent.auditor_config/1` (qb `intent.ex` hunks 1, 3, 4 and 5 only);
- the `auditor` setup guards in `lib/kogen/codex.ex` and `lib/kogen/claude_code.ex`;
- `lib/kogen/codex/environment.ex`'s auditor clause (no helper profiles);
- the fakes and the fixture packages.

Slice 1 landed its own `lib/kogen/shaping_audit.ex`, `report.ex`, `finding.ex`,
`questions.ex`, `lib/mix/tasks/kogen.audit.ex`, `test/kogen/shaping_audit_task_test.exs`
and `test/support/shaping_audit/fixture.ex`. qb's versions of those files do not
apply. Extend the landed files as `evidence/CANDIDATE.md` "Extending the landed
slice-1 code" says.

Leave out of this slice:
- `gate_questions/3` and `gate_questions_main/0` in `jev_layer.ex`: their only
  caller is slice 3's `integrity.py`;
- `tag_current_role` and `shaping_stop_hook/0` in `harness.ex`;
- the Shaper `--search`, the hook flags and the helper descriptions (slices
  3 and 4);
- qb `intent.ex` hunks 6-9: slice 1 landed `commit_subject`, and hunks 6 and 9
  still apply but would add a second `optional_string/2` beside the landed one
  at `lib/kogen/intent.ex:634`.

Fix these defects:
1. **The auditor key must be absent when a route has none** (risk defect (1),
   reproduced by P1 at `test/kogen/lifecycle_test.exs:637`). qb's
   `normalize_role_route/1` (`lib/kogen/intent.ex:266`) merges
   `auditor: raw_auditor(route)` unconditionally, which leaves
   `:auditor => nil`. Rely on `put_raw_auditor/2` only, in both
   `normalize_clean_route/1` (`:231`) and `normalize_role_route/1`. Then
   `lifecycle_test.exs` passes unchanged: its hybrid fixture config has no
   auditor.
2. **Tests never read `.kogen/intents/**`.** The qb Jev and question-gate tests
   read `.kogen/intents/approved/shaping-quality/evidence/...`. That path is
   gitignored, absent in a Candidate worktree, and moved on landing. Ship byte
   copies of the calibration files under `test/support/shaping_audit/calibration/`:
   - `question-set-v1.json`, SHA-256 `6057cdd1169cc62ec746efd07851771dcc9106c94f11fb89ec8380a5419353ef`;
   - `fix-check-v1.json`, SHA-256 `d71c560cc152bacc81a459b7913f9d1d75af5e5e085b47bc88f041cd1d569690`;
   - `question-gate-v1.question.json`, SHA-256 `18de817ba4ee6de027b28f289635d90bc313680ef8880e87afcf1d0039198446`.

   The sources are in this package's `evidence/jev-question-set-v1/` and
   `evidence/jev-routing-calibration/`; the three literals were recomputed with
   `shasum -a 256` on those files on 2026-09-27 and match. The tests pin those digests as literals
   and compare the shipped `priv/` files against the copies.
   `priv/kogen/shaping_audit/question-gate-v1.json` is a byte copy of
   `question-gate-v1.question.json`: its SHA-256 is the same literal. qb's copy
   was re-serialised and differs in bytes.
3. **README.** qb's README hunk does not apply. Insert the "### Jev in the
   Shaping audit" and "### Shaping auditor" sections from it by hand, after
   slice 1's "### Shaping audit" paragraph (`README.md:973-975`) and before
   "## Context index (`kogen-ctx`)" (`:977`). Slice 1's paragraph stays
   byte-unchanged: its test (D8) asserts `mix kogen.audit [--route <name>] <slug>`.
4. **The new fixture packages must not break slice 1's A3.** A3 ("proof
   findings are empty exactly when build/4 accepts, on every fixture Draft")
   loads every directory under `test/support/shaping_audit/drafts/` except
   `invalid` and `non-regular`, and `Fixture.add_draft!/3` reads each one's
   `intent.yaml` for its slug. qb's `jev-clauses`, `jev-large` and `questions`
   have no `intent.yaml`, `flow/` is a directory of packages, and the asking
   packages have no `scenarios.yaml`. Put every package of this slice under
   `test/support/shaping_audit/packages/` (`jev-clauses`, `jev-large`,
   `questions`, `flow/<name>`), each with an `intent.yaml` holding its `slug`,
   and add a `:source` option to `Fixture.add_draft!/3` (default `"drafts"`).
   A3 stays byte-unchanged. qb's `head/` and `workdir/` subdirectories are not
   package files: J4 commits `docs/note.txt` itself and then edits it.
5. **No test seams in production code.** qb's `Kogen.ShapingAudit` takes
   `:layers`, its `Auditor` takes `:launcher` and `:manifest`, and its
   `JevLayer` takes `:jev_transport` and `:jev_security`. None of them ships.
   Tests reach Jev through `KOGEN_JEV_TRANSPORT`/`KOGEN_JEV_SECURITY` in
   `main/2`'s env, and the auditor through `KOGEN_HARNESS`. The one new
   `main/2` option is `jev_deadline_ms:` (a duration, not a replacement).

`.kogen/config.yaml`: qb's hunks 1, 3 and 4 apply. Hunk 2 (the codex route) fails
only on a context line: `developer` is `effort: high` since `bf28f2ca`. Add
`    auditor:   {model: gpt-6-sol, effort: high}` right after the codex route's
`reviewer:` line (`.kogen/config.yaml:16`).

## Exact decisions

- **Report `schema_version` 2** (`@schema_version` at
  `lib/kogen/shaping_audit/report.ex:8`; the landed `Report.status/5` already
  counts any other version as `missing`). `layers` holds `deterministic`, `jev`
  and `auditor`. Each has `status`, and `reason` when the status is not `ok`;
  the landed deterministic layer stays exactly `{"status": "ok"}` when clean.
  - `deterministic`: `ok`, `unavailable` (slice 1's `repository-invalid`), or
    `skipped` with reason "asking the Shaper: only the question checks run" in
    the `asking` state.
  - `jev`: `ok` or `unavailable`.
  - `auditor`: `ok`, `unavailable`, `rejected`, `skipped` or `not-run`, with
    `reused`, `bound_reached`, `launched`, `elapsed_ms`, `session_id` and
    `dropped`.

  `readiness` is `asking` in the `asking` state. Otherwise it is `ready` when no
  blocking finding is open and every layer is `ok`, and `not_ready` otherwise.
  The report's top-level keys are exactly `findings`, `head`, `layers`,
  `not_audited_by_auditor`, `package`, `questions`, `readiness`, `revision`,
  `route`, `schema_version`, `slug` and `state`. The new ones:
  - `state`: `asking` or `autonomous`;
  - `questions`: `{"sections": {"Assumed": [...], "Left undecided": [...]}}`,
    each entry `{"number", "title", "text", "recommendation"}`;
  - `not_audited_by_auditor`: a list of paths (`[]` when nothing was cut).
- **Exit codes.** 0 when ready, 1 when not ready or asking, 2 on usage or a
  refusal. The audit still prints one line, `<readiness>: <revision>`
  (`lib/kogen/shaping_audit.ex:103`). `--auditor` is a new flag. The usage line
  (`:43`) becomes `usage: mix kogen.audit [--route <name>] [--auditor] <slug> |
  mix kogen.audit --status [--route <name>] <slug>`. `--status --auditor` is a
  usage error: exit 2, nothing read, no report.
- **Environment.** `main/2`'s `env` (default `System.get_env()`, as landed at
  `lib/kogen/shaping_audit.ex:22`) is where the audit reads `KOGEN_ROLE`,
  `KOGEN_JEV_TRANSPORT` and `KOGEN_JEV_SECURITY`. The Jev layer passes the two
  Jev values to `Kogen.Jev` explicitly (as `:transport` and `:security`), so an
  audit never picks up a Jev executable from anywhere else. The harness
  executable (`KOGEN_HARNESS`) and the Codex and Claude state roots are read by
  the unchanged adapters from the process environment, exactly as for every
  other launch (`lib/kogen/codex.ex:62`, `lib/kogen/claude_code.ex:179`).
- **Audit order** (`Kogen.ShapingAudit.audit/2`, `lib/kogen/shaping_audit.ex:132`). Dispositions are applied
  before anything reads a finding's open state:
  1. parse `questions.md` once: state, sections and dispositions;
  2. the deterministic layer (`skipped` in the `asking` state);
  3. `Finding.apply_dispositions/2` (`finding.ex:56`) over the deterministic findings. A disputable deterministic
     finding dispositioned `not a defect` is therefore closed before the auditor gate reads it;
  4. the auditor gate: the auditor runs only when no deterministic finding is `open_blocking?/1` after step 3,
     and never in the `asking` state;
  5. the auditor layer, then `Finding.apply_dispositions/2` over its findings;
  6. the Jev layer: the contract questions, the question gate over the `## Ask the Shaper` entries (asking) or over
     the auditor findings (autonomous), and the fix-check over the auditor findings that now carry a `fixed`
     disposition;
  7. readiness over all findings.

  The fix-check runs on exactly the auditor findings (`aud-*`) whose disposition kind is `fixed`. No
  deterministic, question or Jev finding is ever fix-checked: those are recomputed on every audit, so a
  `fixed` disposition on one of them leaves it open while it is still raised.
- **Jev layer.** `priv/kogen/shaping_audit/questions-v1.json` is
  `question-set-v1.json` plus one key, `fix-check`, whose value is
  `fix-check-v1.json`. Decoded, it equals the two calibration files. The splits,
  batches and gates are exactly as the file specifies.
  - Each finding is raised only at its entry's gate and is advisory.
  - Citation requests carry the claim and at most 40 numbered lines from the
    materialization, never from the working tree.
  - At most 4 requests run at once. Each keeps `Kogen.Jev`'s existing 60 s
    per-request timeout (`@timeout_ms`, `lib/kogen/jev.ex:31`). The layer as a
    whole stops after 60 s (Assumed 5 of the original: "Jev in seconds on every
    stop"); `main/2` takes it as `jev_deadline_ms:` (default `60_000`), beside the
    landed `:read` and `:io` options, so a test can use 200 ms. A 429 is retried
    twice with backoff.
  - Every other failure makes the layer `unavailable` (scope `environment`) and
    keeps no partial finding. These include HTTP 500, 401 and 422, invalid JSON,
    a missing answer, an unknown option id, an echoed key, and the layer deadline.
  - The report stores parsed answers and request digests, never response bodies:
    `layers.jev.requests` is the sorted list of the lowercase-hex SHA-256 of every
    request body sent, and `layers.jev.answers` maps each of those digests to its
    parsed answers (per question id: `choice` and `confidence` with
    `probabilities`, or `noul`). No response body, `usage` or raw text is stored.
  - `jev-item-too-large` (a clause over 16 KiB) and `jev-request-too-large` (a
    request over 64 KiB) are advisory.
  - The fix-check sets `still_open: true` when `not_addressed >= 0.6` or when the
    most probable option is `partly`, and `still_open: false` otherwise. So
    `partly` never closes a finding.
  - The fix-check pairs the `fixed` auditor finding with the package scenario that
    the disposition's `<what changed>` text names: the first `scenarios.yaml` id,
    in file order, that appears there as a whole word. When it names none, no
    fix-check request is sent and the finding stays open.
- **Privacy allowlist** (risk `privacy-boundary`). Each request's `state` holds
  exactly the fields its table names (`state` in `question-set-v1.json` and
  `fix-check-v1.json`; `item`, `settled` and `decision` in
  `question-gate-v1.json`), filled only from:
  - the scenario id, split `then` clauses, `wrong_result` alternatives and
    evidence items;
  - a scenario's `given` and `when`, only in `clause-provider-only` requests
    (`question-set-v1.json`, state `given`, `when`, `then_clauses`) and fix-check
    requests (`fix-check-v1.json`, state `scenario {id, given, when, then,
    wrong_result, evidence}`);
  - `proof.offline`;
  - the Outcome and Non-goals items;
  - the numbered `questions.md` entries;
  - the settled list;
  - the paid observation;
  - at most 40 `HEAD` lines per cited claim, with the claim and its citation;
  - an auditor finding's id, rule and message (its bounded title and detail).

  They never carry a diff, working-tree bytes, `risks.yaml`, `approval.md`,
  `references.yaml` or anything under `evidence/`.
- **Question gate.** The route is:
  - cite, when `already_settled >= 0.8`, and `settled_by` names a decision with
    confidence `>= 0.8`, and `confirm >= 0.6`;
  - otherwise controller, when `technical >= 0.5`;
  - otherwise the Shaper.

  A gate request holds exactly two questions, `gate` and `settled_by`, as
  calibrated (`calibrate_gate_v3.py:83` sends both in one request). `confirm`
  goes in its own request after it, only for a would-be citation. Neither
  request ever holds `Kogen.Jev`'s status or objection questions. The gate
  question's instructions name `technical`, `product_ux` and `already_settled`
  as its only valid answers (risk `live-gate-and-codepaths`). A `gate` answer
  outside those ids is re-asked once; a second invalid answer makes the layer
  `unavailable`. `Kogen.Jev`'s own `valid_answer` stays strict.
  `finding-routing-v1` does not ship.

  The settled list sent is `settled.json`'s nine entries followed by the
  package's own `## Settled` entries, appended at run time as
  `{"id": "package-<n>", "text": <entry text>}`; `settled.json` is never
  written. Each routed item is stored in `layers.jev.routes` as
  `{"item", "route", "settled_by", "distributions", "model",
  "wording_version"}`: `item` is `question <n>` or the auditor finding id,
  `route` is `cite`, `controller` or `shaper`, `distributions` holds the
  `gate`, `settled_by` and (when asked) `confirm` answers, `model` is the gate
  file's `model` (`jev-1.13.0`), and `wording_version` is its `version`
  (`question-gate-v1`).
- **Settled list.** `priv/kogen/shaping_audit/settled.json` is
  `{"note": …, "entries": [...]}`. It holds exactly these 9 entries, in this
  order, with `text` byte-equal to `SETTLED` in
  `evidence/jev-routing-calibration/calibrate_gate_v3.py`:
  - `dir-1.7`, `dir-1.11-live`, `dir-1.12`, `dir-1.13`, `dir-1.15`, `dir-1.16`
    and `dir-1.17`, each with `source` "plan/DIRECTION.md 1.x";
  - `shp-auditor-profile`, with `source` "shaping-quality
    01a0d7a9-3642-720e-9809-e4962c3f1670 direction 3";
  - `shp-wait-only-product`, with `source` "shaping-quality
    01a0d7a9-3642-720e-9809-e4962c3f1670 direction 4".

  `shp-one-build` is dropped (Assumed 6). No `source` names a `.kogen/intents/`
  path.
- **`questions.md` grammar.** The sections are `## Ask the Shaper`,
  `## Shaper answers`, `## Left undecided`, `## Assumed`, `## Settled` and
  `## Dispositions`. Any other `##` heading is ignored.
  - An `## Ask the Shaper` entry is a numbered item with `Question:`,
    `Recommendation:` and `Evidence:` lines. `Evidence:` is one of: a path under
    the package's `evidence/`, a `path:line`, a quoted decision, or
    `unproven — <what would prove it>`.
  - `## Assumed` entries need `Reason:` and `Undo:`.
  - A `## Dispositions` line is `<id>: not a defect — <reason>` or
    `<id>: fixed — <what changed>`.
  - The state is `asking` when `## Ask the Shaper` has an entry, and
    `autonomous` otherwise.
- **Auditor setting.** `Kogen.Intent.auditor_config/1` reads the selected
  route's `auditor` entry only:
  - A clean route gives `{:ok, %{harness: <the route's harness>, model, effort}}`.
    A clean route's `auditor.harness` is refused, naming the key.
  - A role-level route needs `auditor.harness`, naming a harness that has
    native helpers in that route. Otherwise it is refused, naming the key.
  - A missing entry gives `{:error, "route <name> has no auditor setting"}`.
    The audit shows it as the auditor layer `unavailable` (scope
    `environment`) and launches nothing.
  - Reading the config never fails for a missing or malformed `auditor`.
- **Auditor launch** (`Kogen.Harness.open_auditor/2` opens exactly that harness
  for a given project directory; `launch_auditor/4` on each adapter). The launch
  passes no deadline and starts one fresh session in its own process group,
  with:
  - `KOGEN_ROLE=auditor` and `GIT_OPTIONAL_LOCKS=0`;
  - stdin = only the rendered `priv/kogen/prompts/auditor.md`, never a line of
    `priv/kogen/prompts/expert.md`;
  - no native helpers: no Claude `--agents`, no Codex `agents.*`;
  - on Codex, `--disable multi_agent --disable apps --disable plugins --disable
    shell_snapshot` (lessons of proving runs 2 and 4), and `--output-schema
    <file>` for the findings schema. The schema has no regex lookaround (Codex
    rejects it; build-reliability's probe);
  - on Claude, `-p` with `--json-schema` and the editing tools denied;
  - no `KOGEN_EXPERT`, no `KOGEN_CODEX_CONTEXT_RECEIPT` and no
    `KOGEN_HARNESS_HOME`: the auditor is never a Build launch, so a harness home
    inherited from a Build session (a Developer running the tests) never
    reaches it;
  - on Codex, the prepared context opened for the materialization directory,
    so `KOGEN_PROJECT_ROOT`, the trusted-project arguments and the working
    directory all name the materialization. The login selector comes from
    `Kogen.Codex.State.project_id/1` (`lib/kogen/codex/state.ex:7`) of that
    canonical path (canonical-project-scope). Do not hash `Path.expand/1`
    separately. A fresh materialization has no project selector, so
    `Kogen.Codex.State.scope_name/2` (`:11`) picks the shared login scope; a
    Shaper who logged Codex in only per project sees the auditor
    `unavailable` with the launch error (risk `baseline-and-anchors`).

  Both setup guards, `management_allowed!/1` at `lib/kogen/codex.ex:380` and
  `lib/kogen/claude_code.ex:476` (their role lists at `:381` and `:477`), add
  `"auditor"`. `launch_auditor/4` never calls them.
- **Question findings** (`Kogen.ShapingAudit.Questions`, extending the landed
  Dispositions parser at `lib/kogen/shaping_audit/questions.ex`). Ids follow
  `Finding.id/2`: `<rule> <entry number>`.
  - `recommendation-without-evidence <n>`: an `## Ask the Shaper` entry without
    a `Recommendation:` or an `Evidence:` line. Blocking, mechanical.
  - `assumption-without-reason <n>`: an `## Assumed` entry without `Reason:` or
    `Undo:`. Blocking, mechanical.
  - `technical-question-to-shaper <n>` (gate route `controller`, asking state):
    blocking, disputable, message "question <n> is technical: decide it and
    record it under ## Settled".
  - `question-already-settled <n>` (gate route `cite`, asking state): blocking,
    disputable, message "question <n> is already settled by `<id>` — move it
    under ## Settled with the citation".

  The two mechanical rules join `@mechanical` in
  `lib/kogen/shaping_audit/finding.ex:13-17`.
- **Dispositions.** The landed `not a defect` shape stays
  `{"kind": "not-a-defect", "reason": <reason>}`. `<id>: fixed — <what changed>`
  is stored as `{"kind": "fixed", "reason": <what changed>}`. A `fixed` auditor
  finding is sent to the fix-check, which sets `still_open` on it (see "Audit
  order"). `Finding.open_blocking?/1` (`finding.ex:70`) treats a `fixed` finding
  as closed only when the fix-check ran and set `still_open: false`. Without a
  fix-check answer it stays open.
- **Auditor layer.**
  - It runs only when no deterministic finding is open and blocking after the
    dispositions are applied (step 4 of "Audit order"), and never in the
    `asking` state. Jev does not gate it.
  - Its prompt is `auditor.md` rendered with the package path, the revision,
    `HEAD` and the `prior-failures` list. Then it inlines, in this order:
    `intent.yaml` without the `revisions`, `baseline_history`,
    `shaping_continuations` and `*approval*` keys; `scenarios.yaml`;
    `risks.yaml`; `INTENT.md`; `questions.md` up to its first heading after
    `## Dispositions`; then the scoped repository files (every path the package
    cites or lists in `affected_paths` and `may_change_guarded_paths`, read
    from the materialization).
  - The inlined text has no per-file cap and 160,000 bytes in total. Any cut
    is marked, and every file left out is listed in `not_audited_by_auditor`.
  - Findings come from the last fenced JSON object, bounded to 50 findings,
    200/1,000 characters and 10 paths, with the dropped counts stored.
  - Each finding is `aud-<first 6 hex of SHA-256(message)>-<n>`, blocking, with
    `auditor_label` kept and its route from the gate. Text with no JSON makes
    the layer `unavailable`.
  - Any write, anywhere, rejects the layer, naming the paths (scope
    `environment`). This covers the materialization, its `.git/` refs,
    `HEAD`, index and hooks, the checkout's watched set, and the report
    directory. Nothing is reverted.
  - Dropping findings over the bound raises blocking
    `auditor-findings-dropped`. It clears only when a later run on a revised
    Draft stays within the bound.
  - Each auditor finding needs a `## Dispositions` line. A "fixed" claim that
    the fix-check marks `still_open` stays blocking.
  - Runs, at most 2 per slug, `HEAD` and route:
    - the first revision whose deterministic layer is clean gets one run;
    - a later changed revision gets a confirming run only when that run was
      `ok` with at least one finding;
    - an `ok` run with no findings is reused with `reused: true` and the
      reason "ran once on HEAD <sha> with no findings; not re-run";
    - a later audit after a rejected or unparseable first run is `unavailable` with
      `bound_reached: true` (the first run's own status stays `rejected`);
    - after the second run, `bound_reached: true`;
    - a launch that failed before the auditor ran does not count.
  - Only records of the same `HEAD` and route count toward the bound.
  - Records go to `.kogen/runtime/shaping-audits/<slug>/auditor/<revision>-<first
    12 hex of SHA-256(route name)>.json` (`Report.latest_revision/2` already
    skips `auditor/`, `report.ex:115`). Each holds the route, harness, model,
    effort, session id, prompt SHA-256, revision, `HEAD`, elapsed ms, status,
    `counted`, `seq` and findings. A route named `../x` writes only inside
    `auditor/`. The materialization is removed after every run.

## Tests and fixtures

Offline only. Jev is the audit-only fake transport
`test/support/shaping_audit/fake_jev_audit` (through `KOGEN_JEV_TRANSPORT`), and
the Keychain is `test/support/shaping_audit/fake_security_audit` (through
`KOGEN_JEV_SECURITY`); both log every call. The auditor is
`test/support/shaping_audit/fake_auditor` (through `KOGEN_HARNESS`). It speaks
both protocols. Starting from qb's copy, it must:
- answer `auth status` first (`Kogen.ClaudeCode.open` runs `<KOGEN_HARNESS> auth
  status` through `System.cmd` before any launch, `lib/kogen/claude_code.ex:414,434`):
  print `{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}`
  and exit 0, without reading stdin or logging anything;
- on the Claude protocol (`-p`), echo the session id the adapter requested (the
  argument after `--session-id`) in every event it prints. qb's fixed
  `fake-auditor-session` is rejected as a mismatch
  (`lib/kogen/harness/claude.ex:407-411`). On the Codex protocol (`exec`) it
  keeps `fake-auditor-session` as the `thread.started` id;
- for each launch, append one line to `$FAKE_AUDITOR_LOG_DIR/launches` (the
  launch count), then log argv, `pwd -P`, the environment, stdin, `git rev-parse
  HEAD` of its working directory (`head`), the sorted list of its files outside
  `.git/` (`files`, replacing qb's hashed `cwd-listing`), and, on Codex, a copy of
  the `--output-schema` file (`output-schema.json`);
- replay a scripted message from `fake_auditor_messages/`, sleep, do one scripted
  write, and, with `FAKE_AUDITOR_FAIL=1`, exit 1 after logging and before
  printing anything (a launch failure).

The cataloged fakes `fake_jev`, `fake_jev.ex`, `fake_security`, `fake_claude` and
`fake_codex` are not edited. `test/support/managed_codex_fixture.py` (the managed
Codex stand-in, `:17-19`) gains two keys in each trace line, `"cwd":
os.getcwd()` and `"project_root": os.environ.get("KOGEN_PROJECT_ROOT")`, and
changes nothing else; no test compares whole trace lines. Tests never read
`.kogen/intents/**` of the real checkout.

**The Build session's environment.** The Developer runs these tests inside its
Build session, whose environment carries `KOGEN_ROLE=developer` and the Build's
`KOGEN_HARNESS_HOME`. `Kogen.IsolatedCase` children and `System.cmd` children
inherit both. Two earlier Reviews found tests that depended on them. So:
- every `Kogen.ShapingAudit.main/2` call in a test passes an explicit `env:`
  map, never `System.get_env()`, and that map always holds the audit-only
  `KOGEN_JEV_TRANSPORT` and `KOGEN_JEV_SECURITY` (a refusal test adds its
  `KOGEN_ROLE` to that map);
- every `Kogen.CompiledFixture.mix_task!/3` call and every fixture Build passes
  `{"KOGEN_ROLE", nil}` and `{"KOGEN_HARNESS_HOME", nil}`;
- `Fixture.audit_env!/1`, below, deletes `KOGEN_ROLE` and `KOGEN_HARNESS_HOME`
  from the test VM before it launches anything;
- no fake writes its log under the checkout: `FAKE_JEV_LOG_DIR`,
  `FAKE_AUDITOR_LOG_DIR` and `FAKE_SECURITY_LOG` always name the test's own
  temporary directory, and `fake_jev_audit` refuses to run without
  `FAKE_JEV_LOG_DIR`.

**Isolation.** Every `test/kogen/shaping_audit_*_test.exs` file uses
`use Kogen.IsolatedCase, async: true`. The two slice-1 files switch from
`use ExUnit.Case, async: true`. Their tests put `KOGEN_HARNESS` and the fakes'
controls into the VM environment, which is safe only in an isolated child.
Waits are on conditions, never fixed sleeps, and `TMPDIR` is never overridden
(lessons 20, 25, 26).

**Fixture helpers** (`test/support/shaping_audit/fixture.ex`, slice 1's):
- `config_yaml/0` gains `auditor: {model: gpt-5.6-sol, effort: low}` in both of
  its routes, `codex` and `other`, after each `reviewer:` line;
- `add_draft!/3` gains `source:` (default `"drafts"`); this slice's packages use
  `source: "packages"`;
- `repo!(compiled: true)` copies `priv/kogen/prompts/auditor.md` and
  `priv/kogen/shaping_audit/{questions-v1.json,question-gate-v1.json,settled.json}`
  from `File.cwd!()` into the fixture root, at the same relative paths, right
  after `Kogen.CompiledFixture.create!/2` and before the initial commit.
  `auditor.ex` and `jev_layer.ex` read them relative to the working directory,
  and `mix_task!/3` runs with `cd: fixture` (`test/support/compiled_fixture.exs:103`),
  whose `@fixture_files` (`:4-29`) hold none of them. `compiled_fixture.exs`
  stays unedited;
- `audit_env!/1` (new) takes the fixture root and makes a log directory under
  `System.tmp_dir!()`, removed `on_exit`. It puts `KOGEN_HARNESS` (the fake
  auditor), `FAKE_AUDITOR_MESSAGE=empty`, `FAKE_AUDITOR_LOG_DIR`,
  `FAKE_JEV_LOG_DIR` and `FAKE_SECURITY_LOG` into the VM environment. It
  deletes `KOGEN_ROLE`, `KOGEN_HARNESS_HOME` and `FAKE_JEV_ANSWERS`. It returns
  `%{"KOGEN_JEV_TRANSPORT" => <fake_jev_audit>, "KOGEN_JEV_SECURITY" =>
  <fake_security_audit>}` for `main/2`.

**`fake_jev_audit`'s default.** With no `FAKE_JEV_ANSWERS` entry for a question,
it answers from its own table of each question id's non-gate answer, at
confidence 1.0:

| Question | Default | Question | Default |
|---|---|---|---|
| `clause-kind` | `observable` | `clause-provider-only` | `offline` |
| `clause-asserted` | `asserted` | `outcome-coverage` | the first scenario-id option |
| `alternative-plausible` | `plausible` | `non-goal-leakage` | `none` |
| `clause-timeout`, `clause-effort`, `clause-weaken` | noul `0.0` | `question-provenance` | `with_provenance` |
| `alternative-caught-evidence` | the first `eN` option | `citation` | `supported` |
| `alternative-caught-strict` | noul `1.0` | `gate` | `product_ux` |
| `paid-observation` | `provider_only` | `settled_by` | `none` |
| `fix-check` | `addressed` | `confirm` | noul `0.0` |

So with the defaults, the Jev layer is `ok` with no finding, and slice 1's exact
finding lists stay exact. qb's default, the first criteria option, can be a gate
option. A `FAKE_JEV_ANSWERS` key is a question id, or `<question id>@<match>`,
which applies only to requests whose JSON-encoded `state` contains `<match>` (an
entry's text, a scenario id or a finding id) and wins over the plain key. A value
is `[choice, confidence]` (the rest spread evenly, as qb), a full distribution
object `{option: probability}`, a `noul` number, or `{"sequence": [value, ...]}`,
whose values are used one per matching request, in order (G7's re-ask). The fake records each call's entry
and exit time in its log (J8).

Each scenario's `tests` key names the ExUnit tests. A label like `J1` is not part
of the name (slice 1's rule). The ledger binds by name. No catalogued test is
renamed or deleted here: `test/kogen/intent_test.exs` (20 rows) and
`test/kogen/harness_role_test.exs` (1 row, "every Codex launch overrides a hostile
inherited role") are edited only by changing bodies and adding tests, so
`priv/kogen/test-reliability.yaml` is guarded and needs no change. harness_role_test's
"no harness exposes an auditor launch" has no ledger row.
