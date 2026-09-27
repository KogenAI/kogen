# Write a failure report for every stopped Build

Shaped against develop fa48e817. Part 1 of 3, split from the approved `durable-builds-and-failure-reports` (see
questions.md, Audit). This part lands first. `build-breakers` (part 2) reads these reports at admission, and
`build-continuation` (part 3) adds continuation fields to them.

This package specifies what a Build must write, print and prompt. How build.ex is structured to do that is up to the
Developer. Function names below either describe the code at fa48e817 or name an API that already exists and must be
kept.

## Launch

```sh
mix kogen.build --route codex failure-reports
```

Every proof is offline, so the codex route applies while Kogen's Claude logins are revoked (DIRECTION rule 51).

## Starting point

`evidence/candidate-b3NQxAsT-f72a58f1.diff` is the Developer's work from two Builds of the original package. It
applies cleanly at fa48e817, but it is a **reference to copy from selectively, not a patch to apply whole**: it mixes
this package's code with build-continuation's and diverges from the spec below in many places. Its own tests are
nearly empty; write the tests below. The spec in "Outcome" wins wherever the diff differs.

Take, then fix as noted:

- `lib/kogen/harness.ex`: `Kogen.Harness.login_command/1`, whole (F6, closed).
- `lib/kogen/harness/provider_marker.ex`: `ProviderMarker.login_failure/1` and its helpers, whole (F6, closed).
- `lib/kogen/build/failure_signature.ex`: `reproduce` read from the frame and copied into the signature (not hashed),
  and `for_stop/2`. Do not take the `Reproduce:` line it adds to `primary_lines/2` (nobody asked for it; the
  frame's `reproduce` reaches the prompt through the signature).
- `lib/kogen/build/failure_handoff.ex`: the `## First failure` block. Fix its `Reproduce:` fallback: in the Candidate it is
  currently `make check`; make it the generic line below.
- `lib/kogen/build/verification.ex`: the login marker on paid-target receipts. Add the cycle failure `reason` it
  lacks (see "A rejected login").
- `scripts/check/offline.py`: `include_reproduce` and the replay's omission of it. Fix the value for every stage
  (in the Candidate it is currently `make check` for non-test stages; replace it; see "The frame carries `reproduce`").
- `lib/mix/tasks/kogen.candidates.ex`: `report_line/1`'s report branch. Add ` (<next_command>)` to `next:`.
- `lib/kogen/build.ex`: the login branches of `settle_transport_failure/4` and `receive_review/5`,
  `login_binding/2`, and the report call sites in `stop/3`, `record_failure/2` and `refuse_publication/4`. Fix the
  category mechanism (see "One category per stop") and the record bytes the report hashes (F1).
- `lib/kogen/build/failure_report.ex`: the category table, `report_path/2`, `classify/1`, `write/3` and
  `record_failure/4` as a skeleton. Fix `write/3` (F1: temp file and a no-clobber rename) and every field listed
  under "Fields" (the divergences are listed below).
- The two `test/support/provider_tails/` files: replace their contents (F7; see "Existing tests and fixtures").

Drop, because it belongs to build-continuation or build-breakers (see Non-goals):

- `lib/kogen/build/continuation.ex` and `test/kogen/build_continuation_test.exs`, whole;
- the `lib/kogen/build/workspace.ex` hunk (`Workspace.published?/2`) and the `lib/kogen/build/tracking.ex` hunk
  (`approved_digest/1` made public); neither file is guarded here;
- in `lib/kogen/build.ex`: the `FailureReport.reconcile(control)` call in `Kogen.Build.run/3`, and the
  `%{"published" => false}` details `refuse_publication/4` passes to the report;
- in `failure_report.ex`: `reconcile/1` (both clauses) and its helper `file_sha/1` if nothing else uses it; the
  table rows `interrupted`, `publication-interrupted` and `session-lost`; the report fields `continues`,
  `budget_state` (and the `budget_state/1` helper), `published` and `continuable`;
- in `kogen.candidates.ex`: the `published:` branch, and the no-report text `report:   none (written by the next mix
  kogen.build)`, which assumes reconcile. Without a report the line is `report: none`.

Divergences in what is taken (the tests below catch them; fix each to the spec):

- `build_id` is read from `record["build_id"]`, which doesn't exist. A record has no build id key; the Build id is
  the tracking directory's name (`Path.dirname(ctx.tracking.path) |> Path.basename()`). As written, an admission
  report lands in `scenario-tracking/unknown/`.
- `slug` and `intent_id` are read from top-level record keys that don't exist: they are under the record's
  `"intent"` map (or use `ctx.slug` and `ctx.intent`).
- `stopped_at` is truncated to seconds; the spec wants microseconds.
- `same_signature_count` is keyed by category and digest; the spec keys it by `intent_id`,
  `approved_package_digest` and signature digest.
- `record` is an absolute path; the spec wants it control-relative
  (`.kogen/runtime/scenario-tracking/<build-id>/record.json`).
- The login messages have no harness name; the spec's format has one.
- `record_sha256` hashes `ctx.tracking.bytes` from before the stop's own record update (F1).
- The recorded detail key `stop_category` is renamed `category_override`, and the prefix table is kept as
  `infer_category_override/1` beside it (F1). Keep the key `stop_category` (see "One category per stop").
- Readiness failures still fall to `integrity`: nothing maps them to `environment`.
- The failed cycle's signature is not saved before the resumed Developer launches, so a real Build's rework prompt
  never gets it (F5).
- The two login tails are bare events, not the committed excerpt wrapper, and no Build-path login tests exist (F7).

F1, F5 and F7 are from the final Reviewer verdict (evidence/last-verdict-b3NQxAsT.txt). F6 (the login marker and
`Kogen.Harness.login_command/1`) is closed: keep both.

## Why (the code at fa48e817)

- A stopped Build leaves only `record.json` and the owner record's `stopped: <category>`. Nothing says what failed
  first, whether rebuilding can help, or what to run next.
- A readiness failure ("… harness claude is not ready: … Run mix kogen.claude.login", from `Kogen.Harness.open_roles/4`)
  matches no prefix in `stop_category/1`, so it is labelled `integrity`.
- A revoked login (lesson 24, Build XfjCRM76YhocUjkONmFsNAZC) returns `is_error: true, api_error_status: 401`.
  `ProviderMarker.classify/1` doesn't recognise it, so it stops as a `provider-failure` with no hint to log in.
- The failed-cycle rework prompt (`Kogen.Build.FailureHandoff.render/1`) has no first-failure line, no way to reproduce
  the failure and no rule against "passes in isolation". Lesson 25: a Developer called a gate-only failure a flake,
  changed nothing, and the Build stopped as `unchanged-candidate`.
- `resume_after_failed_cycle/6` records only the session id, notes and invocation before resuming. Failure signatures
  are written only at settlement (`settle_verification/3`), which a pending cycle never reaches.

## Outcome

### One failure report per stopped Build

Every Build that has a tracking record and then stops writes exactly one
`.kogen/runtime/scenario-tracking/<build-id>/failure-report.json`. That covers every stop, a Candidate admission failure
after the record exists, and a publication refusal.

- **Atomic and final.** The report is written to a temp file in the same directory and then renamed into place. A
  reader never sees a partial report and no temp file is left behind, on success or failure. A report is never
  replaced: writing where one exists keeps the existing bytes and returns the existing path. A POSIX rename replaces
  its target, so the rename alone is not enough: either publish the temp file with a hard link that fails when the
  target exists (then delete the temp file), or check for an existing report and rename while holding the control's
  Build lock (every stop runs inside it). The report is built from the context (or file) after the record's last
  update, so its `record_sha256` is the sha256 of `record.json`'s final bytes. The owner record reads `stopped:
  <category>` only after the report exists; a controller killed between the two leaves the owner `running`, which
  build-continuation reconciles.
- **Not for refusals before admission.** A refusal before the tracking record exists is not a Build and writes no
  report, as today. That covers config, route, Jev key, a live lock, binding resolution and an existing Complete
  Intent: everything in `Kogen.Build.run/3` before `Tracking.new/5`.
- **Fields** (`schema_version: 1`):
  - identity: `build_id` (the tracking directory's name; the record has no build id key), `candidate_build_id`,
    `slug` and `intent_id` (from the record's `intent` map), `approved_package_digest` (the record's), `stopped_at`
    (UTC ISO 8601 with microseconds, so build-breakers can order reports);
  - classification: `category`, `stop_class` (the attempt's value or null), `class`, `counts_toward` (`item`,
    `environment` or null);
  - failure: `signature`, `same_signature_count`;
  - what to do: `next_action`, `next_command`;
  - context: `developer_session_id`, `reason` (first 2,000 characters), `candidate` (worktree, branch, harness home,
    owner record; null with no Candidate), `record` (control-relative:
    `.kogen/runtime/scenario-tracking/<build-id>/record.json`) and `record_sha256`.
- **Signature.** In order: the last attempt's last `failure_signatures` entry; the `unchanged_candidate` signature;
  the last attempt's last `cycle_signatures` entry (see the rework prompt below); otherwise a stop signature, a digest
  over the category and the whitespace-normalized reason (the starting point's `FailureSignature.for_stop/2`).
- **`same_signature_count`** is the number of this control's reports with the same `intent_id`,
  `approved_package_digest` and signature digest, this one included.
- **Message.** The Build's error message gains `; category: <category>; failure report: <path>; next action:
  <next_action>` plus ` (<next_command>)` when there is one. `<category>` is the report's category.

### One category per stop, one table from category to class

A stop's category is decided once. The same value goes into the owner status, the report and the message. Every
category a stop gets at fa48e817 stays the same (existing-expectations-kept), with two deliberate changes:

- a harness readiness failure becomes `environment` (today `integrity`);
- a login rejection becomes `environment` (today `provider-failure`).

`refuse_publication/4`'s report gets category `accepted-unpublished`; its owner status stays
`accepted-unpublished: <reason>`. A Candidate admission failure after the record exists gets category `admission`.

The category is decided in this shape (the Reviewer reopened F1 on the Candidate's shape, so follow it):

- **Explicit where the call site knows it.** The call site passes the category as the `stop_category` detail, as
  fa48e817 already does for the guard, integrity and guard-violation stops. The key stays `stop_category`: it is
  recorded in the attempt, and the Candidate's rename to `category_override` is not taken. The new explicit
  categories are `environment` for every login rejection (Developer turn, Review, paid target) and for the error of
  `Kogen.Harness.open_roles/4` in `open_roles/1` (every error it returns is a readiness failure), carried from the
  admission step to `stop` (for example as a third element of its error). `recorded_bindings/1`'s error in the same
  step keeps today's `integrity`. `record_failure/2` uses `admission` and `refuse_publication/4` uses
  `accepted-unpublished`, as literals.
- **One reason→category function for the rest.** Every other stop keeps fa48e817's `stop_category/1` prefix table,
  unchanged. It is the only reason→category function: the Candidate's `infer_category_override/1` copy is not
  taken, and no second table exists anywhere (rule 44). The guard path's existing call (a guard error's reason
  mapped by `stop_category/1` into the explicit detail) stays: it is the same function, called once for that stop.
- **Evaluated once.** `stop` computes `details["stop_category"] || stop_category(reason)` once, before it writes
  anything, and passes that one value to the report, the message's `category:` field and the owner status
  (`retained/2`). Nothing downstream recomputes a category.

One table, in the new report module, maps category to class, next action and counting:

| category | class | next_action | counts_toward |
| --- | --- | --- | --- |
| `verification-exhausted`, `offline-exhausted`, `unchanged-candidate`, `outer-allowance-exhausted`, `guard-violation`, `protected-path`, `git-policy`, `integrity`, `review-failure` | `item` | `rebuild`; `reshape_details` once `same_signature_count` ≥ 2 | `item` |
| `cannot-comply` | `shaping` | `reshape_scope` | `item` |
| `environment`, `provider-failure` (harness failure with no provider marker), `write-boundary`, `admission`, `publication-failed` | `environment` | `environment` | `environment` |
| `accepted-unpublished` | `environment` | `inspect` | `environment` |
| `provider` | `provider` | `provider_wait` | null |

`class` repeats the existing `environment` and `provider` words, so there is no `provider_down`. `stop_class` and its
values are unchanged. `next_command` is set in two cases, and is null otherwise:

- for a login rejection, the login command;
- for an `environment` stop whose reason already names Kogen's own hint (`Run mix kogen.<…>`, as the readiness errors
  do), that command.

### A rejected login is an environment stop (lesson 24)

A login rejection is recognised separately from `ProviderMarker.classify/1`, which stays unchanged. It covers:

- a Claude `result` event with `is_error: true` and `api_error_status`/`apiErrorStatus` 401, or `error:
  "authentication_failed"`, whatever the text says;
- a Codex `error`/`turn.failed` message matching 401, unauthorized, revoked, "could not be refreshed" or
  "refresh token". Only those events are scanned, never the whole output.

A 403 or a timeout is never a login rejection.

When a Developer turn, a Review call or a paid target that didn't time out is rejected this way, it is not retried,
and the Build stops with category `environment` (explicit `stop_category`) and `stop_class` `environment`.

- **The login command follows the tail, not the role.** `<harness>` is the harness the login marker names (the
  tail's), and the command is `Kogen.Harness.login_command/1` for the Build's binding of that harness: `mix
  kogen.<harness>.login`, plus ` --project` for a project-scope binding, the same hint the readiness errors give.
  With no binding for that harness it is `mix kogen.<harness>.login`. So on the codex route a Review or paid target
  that prints a Claude tail yields `mix kogen.claude.login`.
- **Developer turn and Review.** The Build's message starts ``"developer: <harness> login rejected (401) (class
  environment); run `<command>`"`` (`reviewer:` for a Review), followed by the usual stop suffixes.
- **Paid target.** `verification.ex` has no bindings. For a target receipt whose output carries the login marker, the
  cycle failure gets `class` `environment`, `provider` the marker, and `reason` exactly ``"make <target>: <harness>
  login rejected (401) (class environment); run `mix kogen.<harness>.login`"``, for example ``"make paid: claude
  login rejected (401) (class environment); run `mix kogen.claude.login`"``. No paid retry and no provider rerun is
  spent; the cycle class and the terminal state are `environment`.
- **The Build's stop for a paid target.** Today's environment stop text, "environment failure before any
  provider-backed target: …", is false here. When the settled failure's `provider` marker has kind
  `login_rejected`, the stop reason is instead ``"make <target>: <harness> login rejected (401) (class environment);
  run `<command>`; no retry was spent"``, with `<command>` from the Build's binding as above (for a shared scope it is
  the cycle reason's command). Every other environment stop (a `prepare` environment result) keeps today's text and
  its category from the table.
- The report's `next_command` is the command in the Build's message.

No credential state, login flow or token refresh changes. The refresh race is row `claude-login-refresh-race`.

### The rework prompt names the first failure (lesson 25)

- **Signature saved before the resume.** When a verification cycle fails and the same Developer session is resumed,
  the failed cycle's signature is derived first, the way the `unchanged-candidate` check already derives one (the
  record's settled `failure_signatures` plus this attempt's earlier `cycle_signatures` are the "previous" list). It is
  appended to the current attempt's new `cycle_signatures` list in `record.json` before the resumed Developer
  launches, and the same signature goes into the prompt. Settlement is unchanged, so `failure_signatures`,
  `verification_state`, every digest and every `repeated` flag stay as they are.
- **The block.** The prompt keeps its first line, "Controller verification failed after your turn" (the fakes match
  it). After the header comes a `## First failure` block with the signature's `target`, `first_failure` and
  `error_head` and a `Reproduce:` line. The block ends with the exact sentence:

  > Passes in isolation is not acceptable: reproduce the failure under the gate's concurrency and make it
  > deterministic; an unchanged Candidate stops the Build.

  - The `Reproduce:` line is the signature's `reproduce` value when present. Otherwise it is "run the command that
    `make <target>` runs, whole and at its normal concurrency, not the one test alone; the controller runs `make
    <target>` itself after your turn" (with the target filled in, e.g. `make check`).
  - Both forms name a command the Developer may run, never `make <target>` itself. That keeps the block consistent with
    the header's unchanged "Kogen's Build controller runs the selected targets again after your turn; do not run them
    yourself", and with the Bash gate guard, which blocks `make <target>`.
  - Called with a cycle and no signature, the renderer derives one from the cycle, so the block never depends on
    settlement.
  - The prompt stays within its 24,000-byte bound.
- **The frame carries `reproduce`.**
  - `scripts/check/offline.py` adds `"reproduce"` to the frame `run_stage` builds for a failing stage: the stage's
    own argv joined by spaces, prefixed with the `MIX_ENV` that `run_stage` gives it (`test` for a `mix test …`
    command, `dev` otherwise). A helper `reproduce_command(command)`, used by `run_stage`, computes it. For the full
    test stage (`STAGES[3]`) that is `MIX_ENV=test mix test --exclude live --warnings-as-errors`, the whole suite at its
    normal concurrency; for the compile stage it is `MIX_ENV=dev mix compile --warnings-as-errors --force`.
  - `failure_signature_frame/2` called with only a stage and a log (as existing tests do) adds no `reproduce`.
  - The `--signature-frame` replay omits it.
  - `FailureSignature` copies `reproduce` into the signature but never hashes it, so every existing digest stays the
    same.

### Visible in `mix kogen.candidates`

For each kept Candidate whose tracking directory (the owner record's `build_id`) has a report, `mix kogen.candidates`
adds:

- `class: <class>`
- `next: <next_action>`, plus ` (<next_command>)` when there is one
- `report: <path>`

Without a report it adds `report: none` (nothing else: the Candidate's "written by the next mix kogen.build" text
assumes build-continuation's reconcile). Existing lines are unchanged.

README.md documents the report, its fields, the category table and the frame's `reproduce` field.
scripts/check/README.md documents `reproduce`. Kogen notifies no one (rule 37) and redacts nothing (rule 42).

## Tests the Developer writes

Every new test uses `Kogen.IsolatedCase, async: true` unless its file already uses another case.

- **`test/kogen/failure_report_test.exs` (new).**
  - **Reports from real fixture stops**, using WorkspaceFixture the way build_workspace_test.exs's failure-retention
    matrix does. Each report is decoded and compared field by field.
    - (a) Offline exhaustion (fake_codex, `FAKE_CHECK_FAIL_ALWAYS=1`), run twice in one control. Both are
      `offline-exhausted`, class `item`, `counts_toward` `item`, with a signature equal to the attempt's last
      `failure_signatures` entry. The first has `same_signature_count` 1 and `next_action` `rebuild`; the second has 2
      and `reshape_details`.
    - (b) Jev cannot-comply: `cannot-comply`, `shaping`, `reshape_scope`.
    - (c) Readiness failure (fake_claude, `FAKE_CLAUDE_LOGGED_OUT=1`): `environment`, class `environment`,
      `stop_class` null, `next_command` `mix kogen.claude.login`, owner status `stopped: environment`.
    - (d) Usage-limited Developer turn (ScriptedBuildFixture, `provider_fail: ["developer-1"]`,
      be_n9crq_claude_session_limit.json): `provider`, `provider_wait`, `developer_session_id` `developer-session`,
      `counts_toward` null.
    - (e) Publication refusal (control's branch moved during the Build, as build_workspace_test.exs's "publication
      refuses when …" does): `accepted-unpublished`, `inspect`, owner status still `accepted-unpublished: <reason>`.
    - (f) Missing control `deps/`: `admission`, class `environment`, `candidate` null.
    - For every case:
      - `record_sha256` equals the sha256 of `record.json` read after the Build returned;
      - `build_id` is the tracking directory's name, `slug` and `intent_id` are the package's, `record` is the
        control-relative record path, and `stopped_at` parses as ISO 8601 with microseconds;
      - the error message contains `category: <category>; failure report: <path>; next action: <next_action>`;
      - no temp file is left in the tracking directory.
    - **One category, three places.** For (a) (category from the reason table), (c) (explicit, changed from
      `integrity`) and the Claude login rejection below (explicit), assert that the owner record's status is
      `stopped: <c>`, the report's `category` is `<c>` and the message contains `category: <c>;`, with the same `<c>`
      in all three. For (e), the report's category and the message's are `accepted-unpublished` and the owner status is
      `accepted-unpublished: <reason>`.
  - **No report before admission.** A pre-admission refusal (missing Jev key, unknown route, live lock) leaves no
    record and no report.
  - **Writer and table.** Writing a report where one exists returns the existing path and keeps its bytes, with no temp
    file left. A table-driven test checks every category row above: class, next action and counting; `interrupted`,
    `publication-interrupted` and `session-lost` are not in the table. `same_signature_count` counts only reports
    with the same `intent_id`, `approved_package_digest` and signature digest: a hand-written report that differs in
    any one of the three is not counted.
  - **The saved signature reaches the prompt (F5).** ScriptedBuildFixture with `fail_first: [1]` and
    `provider_fail: ["developer-2"]` (usage-limit tail):
    - the Build stops as `provider`;
    - the record's attempt has exactly one `cycle_signatures` entry, with cycle 1's `target` and `first_failure`, and
      no `failure_signatures`;
    - the report's signature is that entry;
    - the prompt the fake saved for developer-2 (`developer-invocation-2-prompt`) contains `## First failure` with
      that `first_failure`, and the exact "Passes in isolation" sentence.
  - **Claude login rejection on a Developer turn.** WorkspaceFixture `:claude` route; fake_claude with
    `FAKE_CLAUDE_FAIL_TAIL` set to the extracted `output` of xfjcrm76_claude_oauth_revoked.json.
    - One Developer invocation, no retry.
    - `stop_class` `environment`, owner status `stopped: environment`.
    - The message starts "developer: claude login rejected (401) (class environment); run `mix kogen.claude.login`".
    - The report's `next_command` equals that command, and the one-category assertion above holds.
- **`test/kogen/provider_outcome_test.exs`.** The login marker on both committed excerpts, through the existing
  `fixture/1` helper, which checks their provenance:
  - class `environment`, kind `login_rejected`, the harness (claude or codex) and the classifying line;
  - `ProviderMarker.classify/1` returns nil for both login excerpts, and the same values as today for the existing
    429, 529 and capacity excerpts;
  - a `result` event with `api_error_status: 403` is neither.
  - `Kogen.Harness.login_command/1` returns `mix kogen.<harness>.login --project` for a project scope and
    `mix kogen.<harness>.login` for a shared scope or no scope, for both harnesses.
- **`test/kogen/controller_verification_test.exs`.** Add these to "provider markers on Developer and Reviewer turns":
  - a Codex Developer turn with the synthetic refresh tail stops after one invocation as `environment`, its message
    starting "developer: codex login rejected (401) (class environment); run `mix kogen.codex.login`";
  - a Review call with the xfjcrm76 tail stops after one Review call as `environment`, not `review-failure`, its
    message starting "reviewer: claude login rejected (401) (class environment); run `mix kogen.claude.login`";
  - a paid target (`provider_repo!`, through `F.run_cycle!`) printing the xfjcrm76 tail runs the target once (no
    provider rerun, no paid retry spent), its cycle class and terminal state are `environment`, and the cycle
    failure's `reason` is exactly "make paid: claude login rejected (401) (class environment); run `mix
    kogen.claude.login`".
- **`test/kogen/controller_handoff_test.exs`**, next to "verification failure handoff from real mined receipts":
  - the first line is unchanged;
  - the `## First failure` block follows the header with target, first_failure, error_head and `Reproduce:`, plus the
    exact sentence;
  - with a frame that has `reproduce`, the line is that value; without one, it is the generic line naming `make
    check` as what the controller runs, not as what to run;
  - a cycle that failed before any receipt still renders the block;
  - `render/1` with a cycle and no signature still renders it;
  - the prompt stays ≤ 24,000 bytes.
- **`test/kogen/failure_signature_test.exs`.** `reproduce` is copied into the signature, and every existing digest in
  the file is unchanged.
- **`test/kogen/offline_stage_results_test.exs`.**
  - `reproduce_command` gives `MIX_ENV=test mix test --exclude live --warnings-as-errors` for `STAGES[3]` and
    `MIX_ENV=dev mix compile --warnings-as-errors --force` for the compile stage.
  - `run_stage` on a failing command attaches a frame whose `reproduce` is `reproduce_command` of that command (for
    the existing test's Python command, `MIX_ENV=dev ` plus its argv).
  - The `--signature-frame` replay, and `failure_signature_frame` called with only a stage and a log, have no
    `reproduce` key.
- **`test/kogen/candidates_command_test.exs`.** With a report written into a hand-written record's tracking directory,
  `mix kogen.candidates` prints `class:`, `next:` and `report:`. Without one it prints `report: none`.

## Existing tests and fixtures

Fixtures that change:

- **`test/support/fake_claude`** gains `FAKE_CLAUDE_FAIL_TAIL=<file>`: the Developer turn prints the file and
  exits 1. Unset, nothing changes.
- **The two provider tails** become the committed excerpt wrapper (`provenance`, `description`, `harness`,
  `output`), which provider_outcome_test.exs's `fixture/1` checks. Tests write the extracted `output`, never the
  wrapper, to `FAKE_CLAUDE_FAIL_TAIL` and `:provider_tail`.
  - `xfjcrm76_claude_oauth_revoked.json` holds the last decodable JSONL lines of the XfjCRM76 record's
    `attempts[0].developer_invocation.output_tail`, ending with its `result` event. Provenance: build_id
    `XfjCRM76YhocUjkONmFsNAZC`, its source_record_path, sha256
    `ff6224dcdf9300f4033cd8904ead3b88cc4454a59bf2cd4b8fda410f42bf3930`.
  - `synthetic_codex_refresh_failed.json` is labelled `synthetic: true`. It is
    hjeqtbsg_codex_capacity_stream.json's last two lines (its `error` and `turn.failed` events) with only their
    messages replaced by
    "unexpected status 401 Unauthorized: Your access token could not be refreshed because your refresh token was
    already used. Please log out and sign in again.". It keeps that file's provenance (build_id
    `hJeqtBSgm52RC3xO6fMza8gq`, sha256 `6127a090ca307f0b3b14892f0c0cf3d62bebb6ff4fe833d3ffe06e993573ac5e`).

These pass unedited (existing-expectations-kept):

- build_workspace_test.exs:
  - "a Build stopped by #{category} keeps its Candidate, names it and is never reused by the next Build" (every
    category; the second Build of each still gets a fresh Candidate);
  - "the owner record status is running before any provider launch and stopped afterwards";
  - "an edit to the Build's own Approved copy inside the Candidate still fails the Build as an approved mutation";
  - "a missing control deps/ stops before any launch naming mix deps.get, never in control" (its `control_state`
    compares tracked files only, so the report under the ignored `.kogen/runtime/` doesn't change it);
- scenario_lifecycle_test.exs, core_integrity_test.exs, guard_violation_rework_test.exs;
- commit_failure_rollback_test.exs "restores the Approved Intent and leaves a clean worktree when git commit fails";
- write_boundary_test.exs "a confined Build whose roles use a managed runtime stops before admission";
- controller_verification_test.exs "provider markers on Developer and Reviewer turns";
- candidates_command_test.exs "list shows only P's Candidates …", "mix kogen.candidates prints every field …" and
  "the stale running record's Build is correctly detected as gone …" (output matched by pattern);
- build_preconditions_test.exs: "precondition failures never launch the harness" matches readiness errors by
  substring, so the category change and the report suffix leave it passing;
- two_outer_resumptions_test.exs and candidate_verification_test.exs (the prompt's first line).

No existing test is renamed or removed. `priv/kogen/test-reliability.yaml` binds rows by test name (scripts/check/README.md), so
it and `test-reliability-remediation.yaml` stay unedited. Its rows in the touched files must still resolve: the 18
cataloged tests of controller_handoff_test.exs (for example "every Developer message variant yields the same
controller report and reaches Review") and build_preconditions_test.exs's "precondition failures never launch the
harness" and "a missing Jev Keychain item fails before any launch, tracking record or verification context". Adding a
test needs no row.

## Non-goals

- Breakers, and the first Developer prompt of a fresh Build naming the last report: build-breakers.
- Continuation, reconcile of killed controllers, `budget_state`, `continuable`, `continues`, `published`, and the
  categories `interrupted`, `publication-interrupted` and `session-lost`: build-continuation.
- A transcript archive or repro command (session-telemetry-and-event-log, rule 49). Notification (rule 37),
  redaction (rule 42).
- Codex reconnect failures as a provider marker (no recorded sample). Fixing the login refresh race. Detecting a
  revoked token at readiness. A paid target.
- Changing verification.ex beyond the login marker and its failure `reason` for paid targets.
