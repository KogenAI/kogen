# Candidate hunks for slice 2 (shaping-audit-jev-and-auditor)

Applicability: `git apply --cached --check` against a temporary index of develop
b775974ba8b87e723d07122cafa46c2e4395d165 (slice 1 shaping-audit-checks 6b4376e9 and build-breakers landed), per file
and per hunk. The results are in `probe-candidate-at-b775974b/apply-check-qbOzahf8-slice.tsv` (74 of 84 file diffs
apply) and `probe-candidate-at-b775974b/apply-check-hunks.tsv`. Test status is still probe P1 at 3531023d
(`probe-candidate-at-3531023d-RESULT.md`), which ran qb's own slice-1 files, not the landed ones. "qb" is
`candidate-qbOzahf8-f4819c37-codex-slice.diff`; "zuj" is `candidate-ZujYgSGt-555d0af3-slice.diff`.

"Applies" is not "correct": a hunk that applies can still duplicate landed slice-1 code (intent.ex hunks 6 and 9).

| File | qb hunk | Applies at b775974b | Use in this slice |
|---|---|---|---|
| .kogen/config.yaml | 1, 3, 4 | yes | Take. |
| .kogen/config.yaml | 2 | no: its context line is `developer: {model: gpt-6-sol, effort: medium}`, `effort: high` since bf28f2ca | Add `    auditor:   {model: gpt-6-sol, effort: high}` right after the codex route's `reviewer:` line (`.kogen/config.yaml:16`). |
| lib/kogen/intent.ex | 1 (`auditor_config` type) | yes | Take. |
| lib/kogen/intent.ex | 2 | no: it mixes the `auditor: map() \| nil` config-type line with slice 1's landed `commit_subject` type line (`lib/kogen/intent.ex:57`) | Add only `auditor: map() \| nil` to `@type config` (after `offline_retries`, `lib/kogen/intent.ex:50`). |
| lib/kogen/intent.ex | 3 (`put_raw_auditor/2`, `raw_auditor/1` in `normalize_clean_route/1`, `:231`) | yes | Take. |
| lib/kogen/intent.ex | 4 (`normalize_role_route/1`, `:266`) | yes | Take **without** `auditor: raw_auditor(route)` in the `Map.merge/2` (defect (1): it leaves `:auditor => nil`). Pipe through `put_raw_auditor/2` only. |
| lib/kogen/intent.ex | 5 (`auditor_config/1` and its resolvers, after `roles/0` at `:366`) | yes | Take. |
| lib/kogen/intent.ex | 6, 9 (`commit_subject` doc, `optional_string/2`) | yes, but **duplicates** slice 1 (`optional_string/2` is at `lib/kogen/intent.ex:634`) | Do not take. |
| lib/kogen/intent.ex | 7, 8 (`commit_subject` in `normalize_intent/2`) | no (landed by slice 1, `:652`, `:661`) | Do not take. |
| lib/kogen/harness.ex | 1 (Boundary `exports: [ProviderMarker, Claude, Codex]`) | no (landed by slice 1) | Nothing to do. |
| lib/kogen/harness.ex | 2 (`tag_current_role/2` in `role_context/2`) | yes | Do not take (slice 3). |
| lib/kogen/harness.ex | 3 | yes | Take `open_auditor/2` and `launch_auditor/4` only, not `shaping_stop_hook/0` (slice 3). The launch's working directory is the materialization. |
| lib/kogen/jev.ex | all | yes | Take `Kogen.Jev.ask/3`. `request_body/2` (`:126`), `read_notes/3` (`:201`) and `valid_answer/2` (`:416-428`) stay byte-identical. |
| lib/kogen/harness/codex.ex | all | yes | Take `launch_auditor/4` and `auditor_args/2`; add `KOGEN_HARNESS_HOME` to its removed variables. Leave the `shaper_args/3` hook and `--search` (slice 3). |
| lib/kogen/harness/claude.ex | all | yes | Take `launch_auditor/4` and `disallowed_tools("auditor")`; add `{"KOGEN_HARNESS_HOME", nil}` to its role environment. Leave `settings_path/1`, `@shaping_settings_path` and the Shaper `helper/2` clauses (slice 4). |
| lib/kogen/codex.ex, lib/kogen/claude_code.ex | all | yes | Take: `"auditor"` joins `management_allowed!/1` (`lib/kogen/codex.ex:380-381`, `lib/kogen/claude_code.ex:476-477`). |
| lib/kogen/codex/environment.ex | all | yes | Take only `write_helper_profiles!(_generation, %{auditor: true})` beside the `:setup` clause (`:186`). Leave `current_role` and the Shaper `helper_description/2` (slice 3). |
| lib/kogen/shaping_audit/jev_layer.ex | new | yes | Take, without `gate_questions/3`, `gate_questions_jobs/4`, `gate_question/3` and `gate_questions_main/0` (slice 3). Its `:jev_transport`/`:jev_security` opts are removed (INTENT.md "No test seams"). Change: `fix_check_result/2` (diff `:2369-2373`) sets `still_open: true` also when `partly` is the most probable option and `still_open: false` otherwise (qb closes on `partly`, J6); `fix_check_request/2` pairs the finding with the scenario its disposition names, not `finding["scenario"]` (always nil for `aud-*`, diff `:2380-2385`); the report stores `requests`, `answers` and `routes` (INTENT.md "Jev layer", "Question gate"); the package's `## Settled` entries join the settled list as `package-<n>`. |
| lib/kogen/shaping_audit/auditor.ex | new | yes | Take, without the `:launcher` and `:manifest` opts (INTENT.md "No test seams"). Change: an unparseable or rejected first run returns `bound_reached: true` (qb's `to_run_result(record, false, seq == 2)` at diff `:1469` gives false, R6). `parse_message/1` (diff `:1709`) stays public (S8). |
| lib/kogen/shaping_audit.ex | new file in qb | no: slice 1 landed its own (211 lines) | Extend the landed file by hand (see below). Do not take qb's `:layers`, `--stop-hook`, `StopHook`, `shaping_session_status/3` or `Kogen.Check` Boundary dep. |
| lib/kogen/shaping_audit/questions.ex | new file in qb | no: slice 1 landed a Dispositions-only parser (67 lines) | Extend the landed `parse/1` (see below); port qb's section and entry parsing into it. |
| lib/kogen/shaping_audit/report.ex | new file in qb | no: landed (168 lines) | Change `@schema_version` (`:8`) from 1 to 2 and add the new keys to `to_markdown/1`. The landed `status/5`, `latest_revision/2` and `dir/3` stay. |
| lib/kogen/shaping_audit/finding.ex | new file in qb | no: landed (81 lines) | Add `recommendation-without-evidence` and `assumption-without-reason` to `@mechanical` (`:13-17`); extend `open_blocking?/1` (`:70-74`) for the `fixed` disposition. |
| lib/mix/tasks/kogen.audit.ex | new file in qb | no: landed (21 lines) | Only the moduledoc gains `--auditor`; `System.halt(Kogen.ShapingAudit.main(args))` (`:19`) stays. |
| priv/kogen/prompts/auditor.md | new | yes | Take (54 lines; its checklist and `date` rule are asserted). |
| priv/kogen/shaping_audit/questions-v1.json | new | yes | Take (decoded, it equals question-set-v1 plus `fix-check`). |
| priv/kogen/shaping_audit/question-gate-v1.json | new | yes, but wrong bytes | Replace with a byte copy of `jev-routing-calibration/question-gate-v1.question.json` (SHA-256 18de817b…). qb's copy is ae27a189…. |
| priv/kogen/shaping_audit/settled.json | new | yes | Take, minus the `shp-one-build` entry. The two `shp-*` sources name the original by slug and id. |
| test/kogen/shaping_audit_{jev,question_gate,auditor,flow}_test.exs | new | yes | Start from qb, then hold exactly the tests `scenarios.yaml` lists, under those names. Replace every `.kogen/intents/...` read with the calibration copies and literals. Drop the `gate_questions*` describes (slice 3), the Claude-probe describe (slice 4), qb's `FakeDeterministic` (flow) and every `:launcher`, `:manifest` or `:layers` use. |
| test/kogen/shaping_audit_task_test.exs | new file in qb | no: slice 1 landed D1-D8 | Edit the landed file as `auditor-runs-and-findings` lists (D1, D2, D6, D7 and `call/3`), and add R12 and the `--status --auditor` test. qb's version (fake-layer tests, Stop hook) is not taken. |
| test/kogen/shaping_audit_checks_test.exs | not in qb | landed | Edit as `auditor-runs-and-findings` lists (module, `report!/3`, every `main/2` call). |
| test/kogen/intent_test.exs | all | yes | Take the `"parses the real tracked .kogen/config.yaml"` hunk (`:108`, exact codex map `:156-183`, `:185`), then add S1-S3. |
| test/kogen/configuration_support_contract_test.exs | all | yes | Take, then make the assertions exact literals (`:46`, `:223`, `:245`, `:250`), keep `:213`, and add S4 and S7. |
| test/kogen/harness_role_test.exs | all | yes | Do not take qb's in-place flip of `"no harness exposes an auditor launch"` (`:766`); replace that test with S5. |
| test/support/shaping_audit/fake_auditor, fake_auditor_messages/*, fake_jev_audit, fake_jev_audit.ex, fake_security_audit | new | yes | Take, then change (INTENT.md "Tests and fixtures"). `fake_auditor` (diff `:8255-8320`): an `auth status` branch before any logging or `cat` of stdin (exit 0, loggedIn true); echo the requested `--session-id` on Claude instead of `fake-auditor-session` (diff `:8314`); a `launches` line per launch; log `git rev-parse HEAD`, the sorted file list outside `.git/` (not qb's hashed `cwd-listing`) and the Codex `--output-schema` file; `FAKE_AUDITOR_FAIL=1` exits 1 after logging, before output. `fake_jev_audit` (diff `:8400-8500`): the per-question default table, `<question id>@<match>` keys, full-distribution and `{"sequence": [...]}` values, entry/exit times, and no default log directory (it refuses to run without `FAKE_JEV_LOG_DIR`). |
| test/support/managed_codex_fixture.py | not in qb | landed, unguarded until now | Add `"cwd": os.getcwd()` and `"project_root": os.environ.get("KOGEN_PROJECT_ROOT")` to the trace dict (`:18-19`); nothing else (S5). |
| test/support/shaping_audit/drafts/{jev-clauses,jev-large,questions,flow/*} | new | yes, but **breaks A3** | Move to `test/support/shaping_audit/packages/` as full packages, each with an `intent.yaml` holding `slug`. Their `head/` and `workdir/` subdirectories are not package files: the tests commit and edit `docs/note.txt` themselves. |
| test/support/shaping_audit/fixture.ex | not in qb | landed | Add the auditor entries to `config_yaml/0`, `add_draft!/3`'s `:source` option and `audit_env!/1`; `repo!(compiled: true)` (`:30-32`) copies `priv/kogen/prompts/auditor.md` and `priv/kogen/shaping_audit/{questions-v1.json,question-gate-v1.json,settled.json}` into the fixture root before the initial commit (D7). |
| README.md | 1 | no (insertion point) | Insert "### Jev in the Shaping audit" and "### Shaping auditor" by hand after slice 1's "### Shaping audit" paragraph (`README.md:973-975`), before "## Context index (`kogen-ctx`)" (`:977`). Slice 1's paragraph stays byte-unchanged (D8). |

## Extending the landed slice-1 code

- `Kogen.ShapingAudit.main/2` (`lib/kogen/shaping_audit.ex:20`): `parse_args/1` (`:46`) adds `auditor: :boolean`;
  `--status` with `--auditor` returns `:usage`; `usage/0` (`:42`) becomes
  `usage: mix kogen.audit [--route <name>] [--auditor] <slug> | mix kogen.audit --status [--route <name>] <slug>`.
  `run_audit/6` (`:92`) keeps printing `"#{readiness}: #{revision}"`, and exits 0 only for `ready`.
- `Kogen.ShapingAudit.audit/2` (`:132`): after the materialization, parse `questions.md` once (state and sections);
  in the `asking` state skip `Deterministic.run/1`; otherwise run it as today. Then, in this order (INTENT.md
  "Audit order"): `Finding.apply_dispositions/2` (`finding.ex:56`) over the deterministic findings; the auditor
  gate on `open_blocking?/1` of those dispositioned findings (qb's gate at diff `:1331` reads the raw ones, which
  breaks B7 and C2); the auditor layer; `apply_dispositions/2` over the auditor findings; the Jev layer (contract
  questions, the gate routing the dispositioned auditor findings, and the fix-check over the `fixed` ones; qb's
  fix-check at diff `:2357` only ever saw dispositions applied after it); then readiness. The report map (`:171`) gains `state`, `questions`, `not_audited_by_auditor` and the
  `jev` and `auditor` layers. `Materialization.remove/1` stays in the `after` (`:185`).
- `Kogen.ShapingAudit.Questions.parse/1` (`questions.ex:9-16`) keeps `dispositions` and its `not a defect` shape
  (`%{"kind" => "not-a-defect", "reason" => r}`, asserted by B7) and adds `%{"kind" => "fixed", "reason" => r}` for
  `<id>: fixed — <what changed>`, plus `state` (`:asking | :autonomous`) and `sections` (entries per section:
  number, title, text, fields). The landed `disposition_lines/1` (`:29`) and the `—|--|-` separators stay.
- `Kogen.ShapingAudit.Deterministic.run/1` (`deterministic.ex:23`) and `prior_failures/3` (`:461`) do not change.
