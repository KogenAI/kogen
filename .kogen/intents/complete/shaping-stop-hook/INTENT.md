# Audit every Codex Shaping stop

Slice 3 of 5 of the `shaping-quality` split (the approved Intent id
`01a0d7a9-3642-720e-9809-e4962c3f1670`, revision 13, kept as a superseded reference in
`.kogen/intents/drafts/shaping-quality/`). Landing order:

1. `shaping-audit-checks`: `mix kogen.audit`, deterministic checks, `commit_subject`. Landed (6b4376e9).
2. `shaping-audit-jev-and-auditor`: Jev, the question gate, the `questions.md` states and the blind auditor.
   Landed (3962af8b).
3. **this Intent** (offline): the Shaping Stop hook on the Codex Shaper, the Shaping prompts (the process of
   "How Shaping must go"), the Codex research helpers, and the smoke fixture without an auditor.
4. `shaping-evaluation-live` (paid, codex route): the live evaluation under the hook — the driver and integrity
   port, the question gate command, and the two paid targets `live-shaping-quality` and `live-shaping-smoke`.
   It lands right after this one.
5. `claude-shaping-under-hook`: the same hook and helpers on the Claude Shaper, with `live-shape-to-build`. It
   waits for the Shaper's Kogen Claude login.

Split from the earlier single slice 3 on 2026-09-28 after the Opus round 1 review at dece3e84
(questions.md "Audit"): the Stop-hook unit tests were sound; the evaluation port and the paid targets were not.
This Intent carries everything that needs no live run. Shaped against develop
`dece3e84a25e7d3399a3c618b670caf399ea86e1`. Build route: `codex`. **No paid target**: every scenario is proved by
`check`. The one provider behaviour this Intent relies on — the interactive Codex TUI runs a `-c`-registered Stop
hook at a root turn end, on fresh and resumed turns, and continues the same turn when it blocks — is proven by
`evidence/probe-codex-stop-hook-tui/RESULT.md` (plain `codex` 0.157.1, disposable scope). The end-to-end live
proof under the managed 0.156.1 runtime is `shaping-evaluation-live`'s.

## What the Shaper gets from this slice

- **Questions first, then autonomous** (directions 1, 5, 6, 12, 16, 25 and 27). The three Shaping prompts state
  the numbered process of "How Shaping must go" below:
  - The root launches helpers immediately and stays idle.
  - It asks only big UI/UX/DX/product questions with probed recommendations, in the first ~5 minutes, through the
    native picker (Codex `request_user_input`), or by stopping with `## Ask the Shaper` entries.
  - After the window it asks nothing more, and records anything else under `## Assumed`.
  - It proves every risk with the smallest probe, names one exact solution per decision, reshapes against the
    latest `HEAD` by itself, and involves the Shaper exactly twice.
- **The audit runs inside Shaping, automatically** (direction 4). The Codex Shaper gets a command-line Stop hook.
  At every root turn end it runs `mix kogen.audit --stop-hook` with the three landed layers, and blocks a
  not-ready Draft with the findings and what to do. It never traps the session:
  - the same revision stopped again is allowed;
  - the ninth block of a chain is allowed;
  - an environment-only finding is allowed;
  - once the auditor's bound is used up, the stop is allowed with "not ready: auditor bound reached" (option B,
    direction 8).

  It never decides by elapsed time (direction 36). It records the elapsed launch, chain and audit times, and shows
  them. A ready Draft is presented with every `## Assumed` and `## Left undecided` entry. Inside a Shaping
  session, a manual `mix kogen.audit` audits nothing and prints the hook's status (proving run 5 lesson).
- **Helpers research and probe** (directions 5, 13, 35 and 37). The Codex Shaper starts with `--search`. Its
  `worker` helper may probe in disposable directories and edit the Draft files its packet assigns. Its `scout`
  helper may research the web. No other role changes.
- **The smoke fixture has no auditor.** Once the hook runs, the `live-shaping-smoke` fixture would launch the
  project's Sol-high auditor (244-255 s per run) inside its 300 s. The fixture config drops the codex route's
  `auditor:` line and pins its `worker` and `expert` helpers to `gpt-6-luna` low.

The Claude Shaper is unchanged here: no hook, helper tools unchanged, prompt text shared. Slice 5 adds the Claude
side (Assumed 3).

## Starting point (exact)

Slices 1 and 2 have landed. This slice extends their landed `Kogen.ShapingAudit`, `Report`, `mix kogen.audit`,
fakes and tests; it never re-adds them. The Candidate files are in `evidence/candidate-*-slice.diff`; which hunks
apply at `dece3e84` and what to take is `evidence/CANDIDATE.md` (probe P0); the landed audit's exact results on the
fixture packages are `evidence/probe-preflight-dece3e84/RESULT.md` (probe P3).

- **Take as the starting code:**
  - qb `lib/kogen/shaping_audit/stop_hook.ex`, then make every change of CANDIDATE.md "Adapt to the landed code"
    (thirteen numbered changes), and `priv/kogen/shaping_audit/stop_hook.sh` (with `cd "$root"` and relative-path
    hashing);
  - qb `lib/kogen/harness.ex` hunk 2 (`role_context` with `tag_current_role`);
  - qb `lib/kogen/harness/codex.ex` hunk 2 (`shaper_args` with the hook flag and `--search`, `codex.ex:265-267`);
  - qb `lib/kogen/codex/environment.ex` hunks 2-4 (`current_role` in `config_args`, `:426`, and the Shaper
    `helper_description/2` clauses);
  - zuj `lib/mix/tasks/kogen.shape.ex` (the four `KOGEN_SHAPING_*` variables);
  - zuj `priv/kogen/prompts/shaping.md`, `shaping-continuation.md` and `shaping-fresh.md`;
  - qb `test/kogen/codex_environment_test.exs` (one new test);
  - qb `test/support/shaping_audit/fake_mix` and `hook/{root,helper}-rollout.jsonl`;
  - qb `test/support/shaping_evaluation/driver_smoke_rehearsal_test.py` hunks 1 (the `difflib` import) and 4 (the
    pin-test body), tightened to K1's exact diff. Never hunks 2, 3 or 5: they change the catalogued wrong control
    `test_smoke_wrong_control_missing_scripted_answer_fires_fail_fast` and its fake, which belong to
    `shaping-evaluation-live` (it keeps that control unchanged).
- **Not taken here:** qb `test/support/shaping_audit/fast_auditor.ex`. Its only caller is slice 5's
  `live-shape-to-build` test (`FastAuditor.patch!`), and `mix.exs` compiles no `test/support` path, so here it
  would be plumbing without a caller (direction 9). Nothing of the evaluation (`driver.py` beyond
  `pinned_smoke_config`, `integrity.py`, the transports, `jev_layer.ex` `gate_questions*`, the live owners) is in
  this slice; `shaping-evaluation-live` owns it.
- **Add by hand to landed files (qb's whole-file copies no longer apply):**
  - `Kogen.Harness.shaping_stop_hook/0` after `launch_auditor/4` (`harness.ex:359-361`);
  - `--stop-hook`, the inside-Shaping status and `error_text/1` in the landed `Kogen.ShapingAudit`
    (`shaping_audit.ex`);
  - the moduledoc of `lib/mix/tasks/kogen.audit.ex` (its `run/1` stays byte-identical);
  - `lib/kogen/shaping_audit/report.ex` needs no change: `write/3`, `runtime_dir/2` and `latest_revision/2`
    (which reads `hook-state.json`'s `last_revision`) landed.
- **Do not take qb's `test/kogen/shaping_audit_hook_test.exs` harness.** It injects `layers:` fakes that the
  landed `audit/2` does not accept, and its `env/2` never clears `KOGEN_HARNESS_HOME`. Write H1-H28 on
  `Kogen.ShapingAudit.Fixture.repo!/1`, `add_draft!/3` and `audit_env!/1` with the audit-only fakes, under
  `use Kogen.IsolatedCase`. H7, H16 and H26 (flow packages) need the flow checkout: copy the private
  `flow_checkout!/0` of `test/kogen/shaping_audit_flow_test.exs:56-64` into `shaping_audit_hook_test.exs` as its
  own private helper (the flow test's copy stays). The expected results are probe P3's.
- **Keep unchanged:** every name the catalog pins (`priv/kogen/verification_targets.yaml`), the `--prepare
  suite|smoke` protocol, `.codex/**`, `priv/kogen/claude_code/settings.json`, the Makefile, and every catalogued
  test name.
- `test/kogen/shape_task_test.exs`: zuj hunk 1 (the prompt assertions) conflicts with build-reliability's edits.
  Port it by hand into the existing test "fresh shaping guidance requires autonomous outcome-focused
  investigation" (row t003). Leave the Claude tool-list assertion to slice 5.
- **Existing files and tests this slice changes, with their new expectation** (everything else in the guarded
  paths stays byte-identical):
  - `test/kogen/shaping_audit_task_test.exs` "an approved-only package and the Shaper role run normally"
    (`:242-254`, not catalogued): renamed "an approved-only package runs normally". It keeps its first half (the
    approved-only `complete` exits 0). Its second half, which expects `KOGEN_ROLE=shaper` to audit and exit 0,
    moves into H26, where the Shaper role without a hook output audits nothing and exits 1 when no hook report
    exists;
  - `README.md:1018-1019` ("The audit is an explicit read-only command; it does not run as a Shaper Stop hook.")
    and `:1030-1031` ("The auditor is launched only when `mix kogen.audit --auditor <slug>` is requested.") are
    replaced (H27). Slice 1's paragraph `:990-992` stays byte-unchanged, so the landed README test passes
    unchanged;
  - catalogued files that gain tests or have a body extended, with no row change (the landed `ledger-closure`
    rule needs only `priv/kogen/test-reliability.yaml` guarded; it stays byte-identical here):
    `shape_task_test.exs` (t003 body), `harness_role_test.exs`, `codex_environment_test.exs`;
  - `test/support/shaping_evaluation/driver.py`: only `pinned_smoke_config` (and its refusal text) changes;
  - `driver_smoke_rehearsal_test.py` `test_smoke_fixture_pins_codex_shaping_effort_low_and_rejects_unapplied_effort`
    (`:266-284`, not catalogued): its `zip`-based "at most one changed line, same line count" check becomes K1's
    exact diff. It gains K3, and `run_smoke` gains the keyword `hook_files=False` (default path unchanged);
  - `driver_smoke_rehearsal_test.py` `setUp` (`:73-80`, shared by every test in the file; allowed here): the
    synthetic project must be a shape the new `pinned_smoke_config` accepts, and its fixture must ignore the hook's
    runtime files. Its `codex-fake` route gains exactly five lines after its `shaping:` line, and its `.gitignore`
    gains `.kogen/runtime/` (scenario `smoke-fixture-without-auditor` has the exact text). Nothing else in `setUp`
    changes, and the two catalogued controls keep their names and bodies;
  - `test/kogen/shaping_smoke_rehearsal_test.exs:15` and `test/kogen/prepare_test.exs:150`, `:163-166`,
    `:196-202` and `:238` (not catalogued): each `System.cmd` gains `{"KOGEN_ROLE", nil}` and
    `{"KOGEN_HARNESS_HOME", nil}` in its `env:` (added where there is none); names and assertions stay.
- Run `git status --short` before ending any turn; reproduce nothing inside the Candidate root. Never override
  `TMPDIR` (lesson 20).

## The landed audit interface this slice calls (dece3e84)

- `mix kogen.audit` only calls `Kogen.ShapingAudit.main/2` and halts with its code
  (`lib/mix/tasks/kogen.audit.ex`). Landed argv forms: `[--route <name>] [--auditor] <slug>` and
  `--status [--route <name>] <slug>`. Landed exit codes: `0` ready, `1` not ready (including `asking`), `2` usage
  error, refused role (`developer`, `reviewer`, `expert`, `auditor`), `.kogen/build.lock` present, ambiguous or
  missing slug, non-regular entry, or any other audit error. `KOGEN_ROLE=shaper` is not refused. `main/2`
  options: `:root`, `:env` (a map; the audit reads `KOGEN_ROLE`, `KOGEN_JEV_TRANSPORT` and `KOGEN_JEV_SECURITY`
  only from it), `:read`, `:clock` (returns a `DateTime`; documented, not yet used), `:io` (`%{puts, err}`),
  `:jev_deadline_ms`. The audit's own line is `<readiness>: <revision>`.
- `report_error/2` (`shaping_audit.ex:151-169`) prints, for `{:error, reason}`: the message of `{:ambiguous, m}`
  and `{:not_found, m}`; `refusing non-regular package entry: <path>` for `{:non_regular, path}`; otherwise
  `mix kogen.audit failed: <inspect(reason)>`.
- `Kogen.ShapingAudit.audit(root, %{slug, route, auditor, env, opts})` returns `{:ok, report, report_json_path}`
  or `{:error, reason}`. `auditor: true` is the landed `--auditor` (launch when the per-`HEAD` bound allows).
- `report.json` (`Report.write/3`, `schema_version` 2) keys: `slug`, `package`, `revision`, `head`, `route`,
  `state` (`asking` | `autonomous`), `readiness` (`asking` | `ready` | `not_ready`), `layers` (`deterministic`,
  `jev`, `auditor`), `findings`, `not_audited_by_auditor`, `questions.sections` (`Assumed`, `Left undecided`:
  `number`, `title`, `text`, `recommendation`), `schema_version`. `ready` needs no open blocking finding and every
  layer `ok`. `asking` is reported even when a question finding is open.
- Layer statuses: deterministic `ok` | `unavailable` (with a blocking `repository-invalid`, scope `environment`) |
  `skipped` (asking); jev `ok` | `unavailable` (with an advisory `jev-unavailable`, scope `environment`); auditor
  `ok` | `unavailable` (for example "route other has no auditor setting") | `skipped` | `not-run` | `rejected`,
  plus `bound_reached`, `launched`, `reused`, `session_id`, `not_audited`.
- A finding: `id`, `rule`, `layer`, `scope` (`draft` | `environment`), `severity` (`blocking` | `advisory`),
  `route`, `disputable`, `disposition`, `still_open`, `message`, `paths`. `Finding.open_blocking?/1` decides
  "open blocking".

## Exact decisions

- **Hook registration (Codex only in this slice).** `Kogen.Harness.shaping_stop_hook/0` returns
  `%{command: "sh \"$(git rev-parse --show-toplevel)/priv/kogen/shaping_audit/stop_hook.sh\"", timeout: 1800}`.
  The Codex Shaper argv adds exactly one
  `-c hooks.Stop=[{hooks=[{type="command",command=<that command, JSON-quoted>,timeout=1800}]}]`, plus `--search`,
  before `--`. Kogen's `@common_flags` (`codex.ex:10-15`) already carry `--enable hooks
  --dangerously-bypass-hook-trust`, the flags the probe ran with. No other Codex role's argv has either, the
  auditor's included. `.codex/**` and `priv/kogen/claude_code/settings.json` stay byte-identical. `mix
  kogen.shape` sets these, on both harnesses (inert on Claude until slice 5):
  - `KOGEN_SHAPING_INTENT_ID`;
  - `KOGEN_SHAPING_ROUTE`;
  - `KOGEN_SHAPING_LAUNCH_ID`, a fresh UUIDv7 (`Kogen.Intent.mint_uuid7/0`, `intent.ex:667`);
  - `KOGEN_SHAPING_TOOLCHAIN_PATH`, the directories of its own `python3`, `elixir` and `mix`.

  The resume path (`resume_transport.exp`) is the evaluation's and changes in `shaping-evaluation-live`.
- **`mix kogen.audit --stop-hook`.** `main/2` accepts `["--stop-hook"]` alone, dispatches it to
  `Kogen.ShapingAudit.StopHook.run/3` before the role and lock refusals (the hook allows those itself), and always
  returns 0 after writing the output file. `--stop-hook` with any other flag or a slug is a usage error (2). The
  usage line becomes `usage: mix kogen.audit [--route <name>] [--auditor] <slug> | mix kogen.audit --status
  [--route <name>] <slug> | mix kogen.audit --stop-hook`. `main/2` gains `:stdin` (the Stop payload; default:
  standard input).
- **`Kogen.ShapingAudit.error_text/1`** (public, `@doc false`): the text `report_error/2` prints for a reason,
  exactly as listed above. `report_error/2` calls it (its output is unchanged), and the hook uses it for
  `{:error, reason}`.
- **`stop_hook.sh`.**
  1. It re-executes through `.codex/hooks/environment.py` when `KOGEN_ENV_RESTORE_PENDING=1`.
  2. It prints `{"continue":true}` when `KOGEN_ROLE` is not exactly `shaper` (unset included), without starting
     `mix`.
  3. It puts `KOGEN_SHAPING_TOOLCHAIN_PATH` first on `PATH`.
  4. It finds the package whose `intent.yaml` has `id: <KOGEN_SHAPING_INTENT_ID>` under `drafts/` or `approved/`,
     and lists it without following links (`find -P`). Any non-regular entry skips the cache and runs the audit,
     which refuses the entry.
  5. Otherwise its skip key is `git rev-parse HEAD`, `:`, and a SHA-256 over the sorted `<sha256>  <relative
     path>` lines of the package files. When the key equals `hook-state.json`'s `skip_key` and a stored
     `decision` exists, it prints that decision without starting `mix`. Neither a block nor an error is cached:
     after a `blocked` or `error` stop, `hook-state.json`'s `skip_key` and `decision` are null, so the next stop
     re-audits (H13).
  6. It runs `mix kogen.audit --stop-hook` from the repository root (`cd "$root"`), with
     `KOGEN_SHAPING_HOOK_OUTPUT` (a `mktemp` file under `$TMPDIR`) and `KOGEN_SHAPING_SKIP_KEY`, and prints that
     file. A missing or empty file prints
     `{"continue":true,"systemMessage":"the Stop hook produced no decision"}`.
- **Hook decisions.** The hook writes exactly one JSON decision, for the package found by
  `KOGEN_SHAPING_INTENT_ID` under `drafts/` or `approved/`, in this order:
  - a Codex helper thread's Stop: `{"continue":true}`, no audit. The first line of `transcript_path` is the
    rollout's `session_meta`. A helper's `payload.source` is an object with
    `subagent.thread_spawn.parent_thread_id`, and the root's is `"cli"` (evidence/probe-hooks-2026-09-26.md;
    the TUI probe's root is `"cli"` too);
  - a `KOGEN_ROLE` other than `shaper`: `{"continue":true}`, no audit;
  - `.kogen/build.lock` present: `{"continue":true}`, no audit;
  - no package: `{"continue":true}`, no audit.

  These four write nothing under `.kogen/runtime/`. Every other stop runs
  `audit(root, %{slug, route: KOGEN_SHAPING_ROUTE, auditor: true, env, opts})` and is appended to `hook.jsonl`:
  - the same revision stopped again right after a block: `{"continue":true}`, kind `stalled`;
  - readiness `ready`, or `asking` with no open blocking finding: allowed, kind `ready` (with the presented
    summary as `systemMessage`) or `asking` (exactly `{"continue":true}`);
  - only environment trouble (every open blocking finding has scope `environment`, or none is open and a layer
    is `unavailable`):
    `{"continue":true,"systemMessage":"not ready: environment — <messages and layer reasons joined by \"; \">"}`,
    kind `environment`;
  - the auditor layer's `bound_reached: true` (or a bound already recorded for this `HEAD` in
    `hook-state.json`) with open blocking findings:
    `{"continue":true,"systemMessage":"not ready: auditor bound reached; <n> blocking findings remain (<ids joined by \", \">)"}`,
    kind `auditor-bound`, never blocked again at that `HEAD`;
  - open blocking findings, blocks 1-8 of a chain: `{"decision":"block","reason":<block reason>}`, kind
    `blocked`;
  - the ninth successive block of a chain:
    `{"continue":true,"systemMessage":"not ready after 8 blocks in this chain; allowing the stop to avoid a trap.\n<block reason>"}`,
    kind `block-limit`;
  - an exception or `{:error, reason}` from the audit:
    `{"continue":true,"systemMessage":"shaping audit error: <message>; run mix kogen.audit <slug>"}`, kind
    `error`. `<message>` is `Exception.message/1`, or `error_text(reason)` (for a symlink:
    `refusing non-regular package entry: <path relative to the package>`). An error is never cached: the next
    stop audits again, even on an unchanged package.

  The **block reason** is `StopHook.block_reason/3` (public, `@doc false`): `blocking findings:`, one line
  `- <id> (route: <route or none>): <message>` per open blocking finding, then `advisory: <n>` and `report:
  <report.json path>`, joined by `\n`; at most 16 384 bytes. When longer, finding lines are dropped from the end
  and replaced by one line `- … <k> more blocking findings in the report`, so `report: …` stays the last line and
  no UTF-8 character is split. The block and the block-limit message use the same text.

  The **presented summary** (kind `ready`) is these lines, joined by `\n` (no blank lines):
  `ready: <report.json path>`;
  `elapsed: launch <m> min, chain <m> min, audit <m> min (total <m> min), budget <m> min` (minutes to one
  decimal, `n/a` for null);
  `Assumed:` then `- <text>` per entry, or the single line `Assumed: none`;
  `Left undecided:` then `- <text>` per entry (the text carries its `Recommendation:`), or `Left undecided: none`;
  `Not audited by the auditor:` then `- <path>` per file, or `Not audited by the auditor: none`.
  There is no "Disputed" block.
- **The chain.** `hook-state.json` (replaced atomically, `Report.runtime_dir/2`) holds `chain_start`,
  `chain_blocks`, `last_revision`, `last_was_block`, `audit_total_ms`, `auditor_bound_reached`, `bound_head`,
  `skip_key` and `decision` (null after a block or an error). An undecodable file counts as absent. Per kind, the state after
  the stop is:

  | kind | `chain_start` after | `chain_blocks` after |
  |---|---|---|
  | `blocked` | the stored value, or now when none | stored + 1 |
  | `stalled` | null | unchanged (the 8-block escape still counts this chain) |
  | `auditor-bound` | null | unchanged |
  | `ready`, `asking`, `environment` | null | 0 |
  | `block-limit` | null | 0 |
  | `error` | unchanged | unchanged |

  So "the chain resets at every allowed stop" means its **clock** (`chain_start`) resets; its **count** resets
  only on `ready`, `asking`, `environment` and `block-limit` (H4, H5, H16).
  `hook.jsonl` lines hold `at`, `slug`, `head`, `route`, `revision`, `kind`, `report`, `readiness`, `decision`
  (`block` | `allow`), `blocking` (ids), `chain_blocks` (the value after the stop) and `elapsed`.
- **Elapsed.** The hook rewrites `report.json` through `Report.write/3` with `elapsed`:
  - `launch_ms`: the second clock read minus the launch id's UUIDv7 timestamp, or null when the id is not a
    UUIDv7 (the 13th hex digit is not `7`);
  - `chain_ms`: the second clock read minus the `chain_start` **stored before this stop**; 0 when none is stored
    (a block that starts a chain). An allowed stop records the chain it ends (H16: 2 400 000), then clears it;
  - `audit_ms` (second read minus first read) and `audit_total_ms`;
  - `budget_ms`: 900 000, or 1 800 000 when the Draft is complex;
  - `complex`: more than 8 scenarios, 2 or more distinct selected paid targets, or more than 10 regular files
    under `evidence/`.

  "Now" is the landed `:clock` (a `DateTime`, converted with `DateTime.to_unix(t, :millisecond)`), read exactly
  twice per audited stop, before and after the audit. `System.system_time/1` is never read. No decision uses
  these fields.
- **Inside a Shaping session** (`KOGEN_ROLE=shaper` and a blank `KOGEN_SHAPING_HOOK_OUTPUT`): every `mix
  kogen.audit` form except `--stop-hook` (`<slug>`, `--auditor <slug>`, `--status <slug>`) audits nothing,
  launches nothing and writes nothing. It prints exactly two lines:
  `Inside a Shaping session the Stop hook audits the Draft at every stop: end your turn to re-audit`, then
  `last hook report: <readiness> (revision <revision>)` for the newest hook report (`Report.latest_revision/2`,
  then `Report.read/3`) or `last hook report: missing`. It exits 0 when that readiness is `ready`, 1 otherwise.
  The role and lock refusals keep their order and exit 2.
- **Build-session environment.** The Developer's Build session exports `KOGEN_ROLE=developer` and
  `KOGEN_HARNESS_HOME` (`lib/kogen/harness/codex.ex:287`, `lib/kogen/build.ex:639`), and `System.cmd/3` merges its `env:` into the inherited
  environment. So every test in this slice that runs the audit, the hook, `stop_hook.sh`, `mix kogen.shape` or a
  Python process removes both or sets them explicitly: `Fixture.audit_env!/1` (which deletes both) for `main/2`
  calls; `{"KOGEN_HARNESS_HOME", nil}` plus an explicit `KOGEN_ROLE` for every `System.cmd` of `stop_hook.sh` or
  `.codex/hooks/check.sh`; `{"KOGEN_ROLE", nil}, {"KOGEN_HARNESS_HOME", nil}` for
  `Kogen.CompiledFixture.mix_task!/3` and for the Python runners of `shaping_smoke_rehearsal_test.exs` and
  `prepare_test.exs`. The Shaper launch still gets `KOGEN_ROLE=shaper` from `Kogen.Harness.Codex.exec_shaper/4`
  (`codex.ex:257-260`). `driver.py`'s own child environment is `shaping-evaluation-live`'s.
- **Prompts.** `shaping.md`, `shaping-continuation.md` and `shaping-fresh.md` state the process of "How Shaping
  must go" (the exact sentences and substrings scenario `shaping-flow-prompts-and-codex-launch` lists; six
  sentences are inserted into zuj's `shaping.md` word for word), the seven default fixes of
  `question-gate`, the probing rules, and the cbea.ms title and `commit_subject` rules. The removed passages are
  gone from all three.
- **Smoke fixture.** `pinned_smoke_config` (`driver.py:583-595`) keeps pinning the codex route's `shaping` effort
  to `low`, and also deletes that route's `auditor:` line and sets its `worker` and `expert` helper lines to
  `{model: gpt-6-luna, effort: low}` (its `scout` line already is). Other routes are unchanged. Any other config
  shape is refused as today; a codex route without an `auditor:` line is refused with "smoke: the codex route has
  no auditor entry to remove", and one without a single flow-map `worker:` or `expert:` helper line with "smoke:
  the codex route has no single flow-map <name> helper line to pin". The smoke rehearsal's own synthetic project
  (`driver_smoke_rehearsal_test.py` `setUp`) gains the `auditor:` line and `helpers:` block the new function needs,
  and `.kogen/runtime/` in its `.gitignore`, as the real repository has (`.gitignore:13`); probed in
  `evidence/probe-smoke-rehearsal-setup/RESULT.md`.

## Scope and appetite

Three scenarios, no paid target, every proof in `check`. The live behaviour this Intent changes (the hook firing
in a real Shaper, real Controllers under the new prompts, the smoke under the hook) is observed by
`shaping-evaluation-live`, which lands next and selects `live-shaping-quality` and `live-shaping-smoke`. Until it
lands, those two targets are not expected to pass and no Build may select them (risk `evaluation-lands-next`).

The two sections below are carried verbatim from the original's INTENT.md. They are the requirements the three
Shaping prompts must state (scenario `shaping-flow-prompts-and-codex-launch`). Direction numbers are the original's.

## Shaper direction (quoted; this Intent must deliver all of it)

Revision 9 to 11 direction, still in force (verbatim, restored from the
revision-11 INTENT.md):

1. **Questions first, then autonomous.** "when I write my initial prompt I
   should be asked (only) UI/UX/product questions - they should be surfaced
   immedialte if possible or 2-3 minutes max after I write prompt. After
   that it's not me anymore - shaping is done autonomously and any
   assumption that was made incorrectly or something like that should be
   resolved automatically - without involving shaper. … THIS HAS TO BE A PART
   OF THE SYSTEM. WE CAN'T DEFER THAT TO ANOTHER INTENT". Also: "don't time
   it's just for you to realize how quickly I want everything" (superseded
   by the 2026-09-26 time budget). And: "don't bother shaper with too much.
   Only UX/UI/product questions. And even for that see if you can provide
   recommendations (THAT ARE PROBED/PROVEN)".
2. **Leave undecided ≠ decide for me.** "provide recommendations, but don't
   decide if the shaper wanted to leave it undecided".
3. **Three mechanisms.** "1. deterministic scripts/checks 2. jev 3. auditor
   (adversarial in case of 2 routes; if the route is codex, then auditor will
   be sol high, if it's claude it's gonna be opus high; if it's claude with
   codex adversary then sol high, etc.)". Also: "it's not just about
   auditing - it's improving complete shaping quality". Auditor profiles:

   | Route | Auditor |
   |---|---|
   | `claude` | Claude Code `claude-opus-5-5` high |
   | `codex` | Codex `gpt-6-sol` high |
   | `claude-dominant-adversarial-codex` | Codex `gpt-6-sol` high |
   | `codex-dominant-adversarial-claude` | Claude Code `claude-opus-5-5` high |

4. **Inside Shaping, one Build.** "that should all be one intent. 1. audit
   should be running inside shaping session … automatic? 2. … if it's not
   ready it needs to be reshaped but shouldn't block … unless it's a
   ui/ux/product decision/question 3. 1 build".
5. **The auditor is not the Expert.** "Auditor is different than expert!
   Don't combine their prompts in any case! And auditor should have a
   separate setting. We don't want to conflate those two things."
6. **No unnecessary checks.** "Shaping should also not introduce
   unnecessary checks that will just slow down builds without any real
   purpose."
7. **Only Shaping; no Build gate.** "I don't understand your reasoning on
   those two checks. To me they look like irrelevant to this. This is only
   about the shaping." and "Why is there an 'ALWAYS ON' GATE?! WE GOTTA
   REMOVE THAT".
8. **No configuration for behaviour.** "We don't use configs 99.99999% of
   time - every change requires a new build so why would you put it in
   config?"
9. **No plumbing without its caller** ("WE NEVER FUCKING SET UP PLUMBING FOR
   STUFF THAT IS NOT WIRED", DIRECTION 1.16) and **no unrequested splits**
   (DIRECTION 1.17).
10. **Keep it simple.** "don't introduce stupid shit / keep it simple,
    stupid / there might need to be some additional simplicity check?"
11. **Audits must be quick.** "it's all the future shaping sessions - we
    can't let them run hours at a time".
12. **Build now without stopping** (historical approval context): "our
    shaping needs to be better so make sure you add all this knowledge to
    the #3 intent"; "make sure you don't stop for any bullshit".

Revision 12 direction (2026-09-26), numbered 5 onwards within this revision (quotes verbatim):

5. **Subagents research while the Shaper is asked.** "When the initial
   prompt is written, shaping session needs to spawn subagents that will do
   research (on the internet! …), in the codebase, etc. while asking the
   shaper a few questions … the main sessions has to be free to ask
   questions, it shouldn't be doing work, doing research, doing probing etc.
   - that's for subagents!"
6. **Five minutes of the Shaper, then autonomous.** "shaper has to be in the
   flow first 5 minutes - ask him often and quickly while subagents are
   working … after the initial 5 minutes pass - no more questions, don't
   bother shaper, it's just about deriving technical decisions from the
   ui/ux/product ones". Enforced by the prompt for now: "we gotta nudge with
   prompt for now - later we might try with pretooluse askuserquestion hook,
   stop hook etc."
7. **Time budget.** "5 minutes of shaper's attention and 10 minutes of
   autonomous shaping - in total, not more than 15 minutes, 30 max for
   intents that really have many probes, are very complex etc." Which
   Intents count as complex is "Derived automatically".
8. **The loop always ends (option B).** When the auditor's per-HEAD bound is
   used up, the hook allows the stop with a visible "not ready: auditor bound
   reached" message instead of blocking again.
9. **Fold in the 8 proven fixes, align with #4, and prove the path before
   approval** (lesson 18).
10. **Commit subjects follow https://cbea.ms/git-commit/, with no commit
    message body.**
11. **Shaping probes, and proves, before it calls anything ready** (the
    Shaper, in the `build-reliability` session): "shaping IS actually
    supposed to probe things / we can't go into build with questions
    unanswered and assumptions not proven", and "you don't need to run full
    build, full shape or whatever but you can create your own mini-project".
    See `plan/staging/shaping-probing-HANDOFF-2026-09-26.md`.
12. **The root session stays idle; helpers do all the work, including
    probes.** "why are you running full test :/ that's crazy / what do you
    need to probe? Go quickly / run faster subagents it's crazy that you're
    implementing probes yourself / shaping controller needs to be free to
    just react quickly to shaper's inputs, finished probes by subagents etc.
    / shaping controller should be idle most of the time". Also "we really
    gotta make sure to keep developer/shaper in the flow, in the zone / we
    can't do it if you go investigate for 10 minutes and then start asking
    questions / shaper is already on Twitter or something like that".
13. **Research documentation on the web before guessing.** "why don't you
    research on the internet instead of guessing? I'm sure they documented
    that somewhere" (said when the Controller wrote a probe to discover
    Codex's documented `shift+←` question key).
14. **Respect the time budget, and say where things stand without being
    asked.** "are we done? What are you still doing? This session started
    an hour ago I think / what the fuck are you still doing?" (this
    continuation ran about 1.5 hours and chained six paid runs).
15. **After the window, ask nothing, not even something the Controller
    thinks is important.** "don't ask me shit now it's over" (said when the
    Controller asked a picker question after the 5 minutes).
16. **Only big UI/UX/product decisions reach the Shaper.** "it was asking me
    about soem miniscule details that aren't UI/UX/product
    questions/decisions. WE gotta fix that. Shaper is there for UI/UX, big
    decisions that everything else can be derived from. This needs to be
    improved so that all future shaping sessions are fixed." Also, from the
    `build-reliability` session: "I'm being asked too many technical stuff
    that doesn't really matter / we're fixing the shaping so that should go
    there".
17. **Every remark about Shaping is a requirement for all future Shaping.**
    "that has to be a part of this intent / when I tell you something about
    shaping you … have to write it down because we're trying to improve
    future shaping sessions, not just this one / find everything I was
    telling you in this conversation and write it down".
18. **Environment facts the Shaper supplies are used at once.** "there's
    the shift + left arrow thing for answering question in codex"; "try
    again" (after removing the stray `plugins/`).
19. **The Shaper's words are written down and are final.** "most of the
    input in shaping session needs to be written down / shaper is not there
    putting words in the wind, talking gibberish - there's a reason shaper
    is saying something / in every shaping session shaper's word is the
    final / AI/LLMs can/should probe things, but when he says something it
    needs to be written down in that shaping session's intent because it is
    probably something very important!"
20. **Commit subjects: the slug is often the better subject.** "also, the
    commit messages are written in the intent during shaping, right? I don't
    like these long ones. Even the intent name had something that could have
    been turned to a commit message much better" (about "Own verification
    in the Build controller with Candidate-bound receipts" against the slug
    `fortify-paid-verification`), then "https://cbea.ms/git-commit/ but no
    commit message body".
21. **The reshape brief, verbatim essentials.** "Reshape this Draft so it
    can pass its own verification." "Loop that always ends (option B). When
    the auditor's per-HEAD bound is used up, the Stop hook allows the stop
    with a visible 'not ready: auditor bound reached' message instead of
    blocking again. Flawed Drafts can end not ready; the session is never
    trapped. No timeout is raised and no check is weakened." "the auditor
    at most once per HEAD by default (the second run only when the first
    found blocking findings and the Draft changed), with a hard per-run
    limit sized to the budget (e.g. 3 minutes), not 600 s"; "deterministic
    checks and Jev in seconds on every stop"; "record the elapsed Shaping
    and audit time in the report so the budget is observable"; "The live
    evaluation's per-case budget stays 600 s and must now be enough by
    design." "Don't present the Draft as ready until that run passes or its
    remaining failure is a recorded product question." "Keep the Shaper's
    rules: no plumbing without a caller, no unrequested splits, no raised
    timeouts." "The Developer must restore from it, not re-implement." (Superseded by direction 26.)
22. **Status on demand is a failure signal.** "what's going on?" was asked
    mid-run, before "are we done? …" (direction 14). The Controller reports
    progress unprompted.
23. **Handoffs from other sessions are inputs.** The Shaper passed
    `build-reliability/HANDOFF.md`,
    `plan/staging/shaping-probing-HANDOFF-2026-09-26.md` and
    `plan/staging/shaping-preflight-audit-PARKED.md` by path, with no
    comment. A file the Shaper points to is read in full and folded into the
    Draft in the same turn.
24. **Picker questions the Shaper rejects are not re-asked.** The Shaper
    rejected a picker question after the window ("don't ask me shit now it's
    over"). The Controller decided it itself and recorded it under
    `## Assumed`.
25. **Shaping works autonomously until the Intent is ready for approval, and
    the Shaper is involved exactly twice.** "another thing that sucks with shaping: I ran mix kogen.shape
    isolated-candidate-workspace --route claude-dominant-adversarial-codex
    and it stopped here instead of making sure the draft is ready for
    approval … it could have done a lot on its own / for example, it should
    have reshaped against the main, probed whatever needed probing... / why
    did it stop here? Shaping needs to be fixed so that quesitons like
    'Should I do it?' 'Confirm you want this probed' and stupid shit like
    that should be removed / shaping sessions need to work autonomously
    until intent is ready for approval!!!! / shaper should be involved in
    two cases: 1. frontloaded questions about UI/UX... big questions, not
    about miniscule details, and especially not technical questions that
    don't affect customer directly... only stuff UX/DX/UI questions are for
    shaper 2. intent is ready for approval, pretty much shaper just says
    'Approved' or something liek that and shaping is over, it can go to
    build". Also, in that session: "bro never stop, always probe what needs
    probing / reshape against the latest head etc."
26. **Drop every reused implementation** (Shaper, 2026-09-26, after Build
    `IEf3rtZ8xYuvEPSj_gtdanD8` did nothing because the Developer could not
    restore from the backup branch and all 3 verification cycles plus one
    paid `live-shaping-quality` run were spent on an empty Candidate).
    "Drop every reused implementation. The Intent has changed a lot since
    those snapshots, so the Developer implements this Intent from scratch on
    7ed41f66. Remove from INTENT.md, intent.yaml, references.yaml,
    questions.md and scenarios as Build inputs: backup/shaping-preflight-audit-fix3
    (61be8365) and 'restore from it, not re-implement'; backup/shaping-preflight-audit-candidate-r10
    (863e1477) and the partial-Candidate stash; backup/cross-harness-with-auditor-30b96fa0
    (30b96fa0); any prototype diff that patches those files. Keep only
    lessons, as plain prose requirements (what broke and what must hold),
    never as code to copy. No Build step may depend on a branch, stash or
    scratchpad that isn't on main." "Never go to Build with an unproven
    assumption." "Default fixes, no questions to me".
27. **The driver stays free** (reinforces direction 12). "shaping
    driver/controller needs to be \"free\"/idle - it shouldn't be reading
    files, investigateing... it should be free to talk to shaper and for
    synthesis / subagents should be doing all the work".

28. **Naming this Intent, and the slug versus the title** (the Shaper, this
    continuation, after being told the Build spent 3 cycles on an empty
    Candidate): "write that in the shaping quality intent / and you should
    probably rename the intent / shaping-preflight-audit doesn't suffice /
    also, what about commit messages - what's the rule now?" Controller
    decision: the slug becomes `shaping-quality` (the Shaper's own name, "the
    shaping quality intent"); the id is unchanged; the title becomes "Improve
    Shaping quality" (23 characters, imperative, capitalised, no trailing
    period), per direction 20 (the slug is often the better subject). The
    root moves the package directory afterwards.
29. **The commit rule, corrected** (the Shaper, this continuation, after
    direction 20/28): ""Commit messages, the rule now: the Intent's title is
    the commit subject." - not necessarily - more chars can fit the message
    than should be normal for intent name, right? But yeah, it can be (very)
    similar usually". Controller decision: `title` and the commit subject are
    two related but separate fields. `intent.yaml` gains a
    `commit_subject` field that the audit requires on every Draft
    (`commit-subject-format`) (cbea.ms: imperative, capitalised, no
    trailing period, no body; aim at most 50 characters, hard limit 72). Build
    commits `commit_subject` as the subject, falling back to `title` for an
    older package that has none, plus the unchanged `Kogen-Intent-ID` and
    `Kogen-Intent` trailers, no body. `title` stays the Intent's short name
    (at most 50 characters, capitalised, no trailing period), usually very
    similar to the subject, and the slug is often the better basis for both.
30. **Shaping must prove the end result is viable, not just its own
    scenarios** (the Shaper, this continuation, after being asked whether
    the end result had been probed): "so did you probe the end result? Did
    you see if it's viable? Brosky, shaping should be doing that kind of
    stuff and this is exactly the intent that's supposed to bring that
    change. We can't have asumptions at the point this goes into build /
    everything sohuld be clear - we should have clear answers which
    solution should be used / developer should be stupid copy and paste
    monkey / shaping is the real deal - that's where everything that could
    possibly go wrong is found out!" Controller decision: this is the
    "risk-first proof, clear answers" process in "How Shaping must go"
    below, delivered through `shaping.md`/`shaping-continuation.md`/
    `shaping-fresh.md` (scenario `front-loaded-questions`).
31. **How far Shaping goes before Build** (the Shaper, answering the
    Controller's question): "focus on risks, and very small prototypes /
    don't reuse full slow probes :/". Controller decision: probes stay the
    smallest thing that settles a named risk or assumption, never a full
    live target, full Build or full Shape run used as a probe (this
    restates and sharpens direction 11 and the existing `shaping.md`
    probing rules).
32. **This Intent is the mechanism for improving Shaping itself** (the
    Shaper): "write in the intent how the shaping process should go - as I
    said, this intent IS FOR IMPROVING SHAPING THE WAY I SAID!!!!"
    Controller decision: "How Shaping must go" below states the complete,
    numbered session process, consolidating directions 1, 2, 5, 6, 7,
    11-19, 22-28 and 30-31, and the three Shaping prompts state it.
33. **What "probe" means** (the Shaper, this continuation): "when I say
    "probe" I don't mean run the full test suite / I mean create small
    prototypes that probe only the things we are adding, things we aren't
    sure work yet". Controller decision: step 4 below states this exactly;
    a probe prototypes only the new or uncertain part, never the full test
    suite, a full live target, a full Build or a full Shape.
34. **The cheapest check that observes the claim (DIRECTION §1.19).** "Add
    to this Intent: the Shaping prompt (priv/kogen/prompts/shaping.md, the
    proof/paid_target section) and the Shaping audit enforce DIRECTION
    §1.19. When a scenario needs a narrow observable, Shaping designs the
    cheapest check that observes it and adds it in the same Intent: offline
    test, then offline replay of retained real provider evidence, then a
    minimal live smoke, and an existing expensive target only when its full
    observable is needed. The audit flags a paid target whose main
    observable is broader than the scenario needs; its default fix is to
    introduce the cheaper check, never a Shaper question. Prove it with the
    build-reliability case: a Draft selecting live-shaping-quality only for
    driver mechanics is flagged."
35. **Session interruptions are Shaping defects too.** "I don't know what got
    fucked up / you might need to rerun 3 background agents / for some reason
    it closed the session probably when you renamed?! / and then I also had to
    rename the folder because it couldn't restart the shaping session". The
    Controller had changed the slug in `intent.yaml` while the directory kept
    the old name; `mix kogen.shape … shaping-preflight-audit` then refused
    with "draft intent.yaml slug does not match selected slug". In the same
    session, three Shaper `kogen-worker` helpers refused assigned Draft edits
    because `helper/2` in `lib/kogen/harness/claude.ex` makes every
    non-Developer worker read-only.
36. **No hard time limits; sessions manage their own time.** "there shouldn't be hard limits for now, no killing auditors, shaping sessions etc. / but it should be written that they should manage themselves by running date at the start of their session and then measuring that throughout the session". This
    supersedes the auditor kill (180 s, then 300 s), the hook's
    10/30-minute chain cutoff and the "30 s left" auditor skip. The time
    budget of direction 7 stays as a target each session measures itself.
37. **Codex helpers too, and the root stays free.** "why aren't you using
    subagents for work? You should be free to answer my questions very
    quickly / and future shaping sessions too" and "Not just kogen-workers /
    thhhhhhhere are codex workers too".

## How Shaping must go (the process this Intent installs)

This section is the numbered session process that `priv/kogen/prompts/shaping.md`,
`shaping-continuation.md` and `shaping-fresh.md` must state (scenario
`front-loaded-questions`; those prompt files are this Intent's deliverable).
It consolidates directions 1, 2, 5, 6, 7, 11-19, 22-28, 30 and 31 into the
order a session actually runs in:

1. **Start.** The root immediately launches helpers for the codebase, every
   supplied source and handoff in full, and web documentation, and starts
   probing through them. The root reads nothing and probes nothing itself;
   it stays idle, free to talk to the Shaper and to synthesise (directions 12,
   27).
2. **First ~5 minutes.** When, and only when, a real product question is
   still open, the root asks only big UI/UX/DX/product questions,
   through the native picker, each with a probed recommendation, while the
   helpers keep working. It never asks a technical, process or permission
   question ("Should I do it?", "Confirm you want this probed" — direction
   25). Every one of the Shaper's words, in the picker or otherwise, is
   written into the Draft verbatim and is final (directions 2, 14, 19). A
   request that already settles every product choice gets no question.
3. **After the window.** The root asks nothing more. Technical decisions are
   derived from the Shaper's answers, and anything else is recorded under
   `## Assumed` with `Reason:` and `Undo:` (direction 16). Environment facts
   the Shaper supplies are used at once, never re-derived (direction 18). A
   handoff file the Shaper points to is read in full, by a helper, and
   folded into the Draft in the same turn (direction 23). Shaper workers may
   write, but only their disposable probe directories outside the
   repository and the Draft files their packet assigns, on both harnesses:
   Claude `kogen-worker` and Codex native workers alike (directions 35 and
   37). A provider probe in a disposable directory is not a verification
   gate.
4. **Risk-first proof.** Every risk and assumption behind each scenario,
   proof and paid target is listed, including whether the end result works
   at all (direction 30). Each one is proved with the smallest possible
   prototype or probe that settles it, in a disposable worktree or
   mini-project on the current `HEAD`, through Kogen's own launch path, on
   every harness it reaches (direction 11). A probe prototypes only the new
   or uncertain part being added, "the things we are adding, things we
   aren't sure work yet" (direction 33), never the full test suite, a full
   live target, or a full Build or Shape run used as a probe (directions 31
   and 33, restating lesson 12). A helper researches documented behaviour on
   the web before writing a probe to discover it (direction 13). Command,
   result and limitation are recorded under `evidence/`. Each scenario's
   verification uses the cheapest check that observes its claim, designed
   and added in the same Intent (direction 34): an offline test, then an
   offline replay of retained real provider evidence, then a minimal live
   smoke, and an existing expensive target only when its full observable is
   needed. A paid target already selected by another scenario of the same
   Intent costs nothing more and may be shared.
5. **Clear answers.** The Draft names exactly one chosen solution per
   decision — exact files, functions, flags, prompt text, schema, algorithm
   and thresholds — with its proof (direction 30). The Developer implements
   it as written, with no design choice of its own: no "the Developer
   decides", no alternative left open, and no unproven assumption at
   approval. A proven small prototype fragment may be included inside the
   package itself (never on a branch, per direction 26) as the exact
   solution.
6. **Autonomous reshaping.** The session reshapes against the latest `main`
   by itself and keeps going until the Draft is approval-ready; it never
   stops to ask a permission question (direction 25). It reports progress
   without being asked (direction 22). It runs `date` at the start of the
   session and again at each step, and states the elapsed time when it
   reports (direction 36); nothing kills it. A slug rename changes the directory
   first and the slug second, in one step, and tells the Shaper the new
   `mix kogen.shape` command (direction 35). It respects the time budget: 5
   minutes of the Shaper, then 10 minutes autonomous, 30 at most for a
   complex Draft (direction 7).
7. **The Shaper, exactly twice** (direction 25). Once for the front-loaded
   big questions in step 2, and once at the end, where "Approved" ends
   Shaping. Between those two points the session never asks anything else.


## Lessons carried (what broke, what must hold)

From `evidence/proving-run-2026-09-26/README.md` (runs 1-6) and questions.md
R12-2, not as code to copy:
- The auditor's brief must match how it runs: an 8-minute brief under a 180 s
  kill wasted every run (run 1). Revision 13 removes the kill and tells the
  auditor to measure its own time with `date`.
- The Codex auditor must disable `multi_agent` and carry `--disable apps
  --disable plugins --disable shell_snapshot`; without the disable, a
  `plugins/` directory appeared in the shared scope and later launches
  refused (runs 2 and 4).
- The auditor answers in one pass from an inlined, bounded package with no
  tool exploration; tool-exploring took about 25 s per step and was killed
  before finishing a scoped read (run 3).
- (Historical, no kill now.) The evaluation had to accept a Kogen-killed auditor at every completion
  check, including `integrity.py`'s loop over owned sessions, not only the
  auditor-specific check (run 3).
- Auditor sessions must attribute only to the case's own auditor records;
  auditors run in materializations, not fixtures, so a naive correlation
  attributes every auditor to every case (run 6).
- Inside a Shaping session, `mix kogen.audit` audits nothing and prints
  status; a root that ran it itself spent 430 s doing so (run 5).
- The driver must answer native question panels; Codex's own
  `request_user_input_async` is on by default and the driver cannot leave
  it unanswered (run 6).
- A bound turn that the driver aborts at its deadline is a timeout, never
  "malformed" or a provider failure (questions.md R12-2 and the transport
  correlation lesson).
- Once the auditor's bound is used up, the hook must allow the stop
  (option B), or sessions are trapped waiting on a kill that already
  happened.
- The deterministic layer mirrors #4's admission predicates rather than a
  separate pre-#4 proof model.
- Evidence probes are data, never code to run in place (lesson 21). The
  `.py` files under `evidence/` (for example
  `evidence/jev-routing-calibration/*.py`,
  `evidence/jev-question-set-v1/jev_audit.py` and
  `evidence/audit-round-*/fix_check*.py`) are never imported or executed
  from `.kogen/intents/**`. Copy a probe to a scratch directory first, then
  run the copy with `python3 -B`, so no bytecode is written into the
  package.


## Non-goals

- A hook that enforces the 5-minute window or the question kind, such as a
  PreToolUse hook on `AskUserQuestion` or a timed Stop-hook block. The Shaper
  said "later".
- A Build gate, or any change to how Builds start, the Makefile, the catalog,
  `.codex/**`, Developer/Reviewer settings or prompts, or the Build-handoff
  Jev request.
- The live evaluation under the hook (the driver and integrity port, the
  resume transport's hook override, the question gate command, `SMOKE_REQUEST`,
  both live owners and both paid targets): `shaping-evaluation-live`, which
  lands next.
- Headless Shaping and the question inbox (SHP-02), Studio approval (SHP-04),
  completeness detectors and epic decomposition, the Rust hook entrypoint,
  and process custody for other roles.
- Raising any timeout, including the evaluation's 600 s per case.
- Pinning controller module generations across a Build (ROADMAP order 6,
  `bind-controller-generation`), owned by that row.
- Login-scope keys, harness selection and route configuration semantics
  beyond the `auditor` config entries slice 2 landed, and catalog
  semantics beyond this Intent's own targets; each is owned by its own
  ROADMAP row.
- The Claude Shaper's hook, `--settings`, helper tools, `test/support/shaping_audit/fast_auditor.ex` and the `live-shape-to-build` probe: slice 5 (`claude-shaping-under-hook`).
