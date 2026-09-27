# Add the deterministic Shaping audit

Slice 1 of 4, split on 2026-09-27 from the approved `shaping-quality` Intent
(id `01a0d7a9-3642-720e-9809-e4962c3f1670`, revision 13; kept as a superseded
reference in `.kogen/intents/drafts/shaping-quality/`). Landing order:

1. **this Intent**: `mix kogen.audit` with the deterministic checks, and the
   `commit_subject` field;
2. `shaping-audit-jev-and-auditor`: Jev contract questions, the question gate,
   the `questions.md` states and the blind auditor;
3. `shaping-stop-hook`: the Stop hook on the Codex Shaper, the Shaping prompts
   and the live evaluation;
4. `claude-shaping-under-hook`: the Stop hook and research helpers on the Claude
   Shaper, with `live-shape-to-build`. It waits for the Shaper's Kogen Claude
   login.

Shaped against develop `e65392cf5d9265f0e0e9c8dae1e078ba4ddfb533` ("Write a
failure report for every stopped Build"). Build route: `codex` (DIRECTION rule 51; Developer
`gpt-6-sol` high, rule 54; Reviewer `gpt-6-sol` high). Every proof here is
offline.

## Why this slice exists

The Shaper approved `shaping-quality` as one Intent and one Build (13
scenarios, 3 paid targets). Its codex-route Build `qbOzahf8VYUfRIBFv61jH-_a`
did not converge: 11 check failures, with the same blockers across 4 cycles
(risk `codex-route-attempt-qbozahf8`). Lesson 27 applies: on the codex route,
keep an Intent to 3-5 scenarios, list the tests to write, and split at the
first non-converging stop. The orchestrator split the Intent under DIRECTION
rules 43 and 46.5. The split only reshapes the technical delivery. Every
UX/DX outcome the Shaper approved is carried by one of the four slices
(`questions.md` "## Audit" maps each one).

## What the Shaper gets from this slice

- **`mix kogen.audit <slug>`** audits one Draft (`.kogen/intents/drafts/<slug>`)
  or Approved package (`approved/<slug>`) with the deterministic checks. It
  never creates, changes or removes anything under `.kogen/intents/`. It writes
  `report.json` and `report.md` to
  `.kogen/runtime/shaping-audits/<slug>/<revision>/`. It exits 0 when ready, 1
  when not ready, and 2 on a usage error or a refusal. `mix kogen.audit
  --status <slug>` prints `current`, `stale` (naming what changed) or
  `missing` without auditing again. **A report is never approval.** In this
  slice, only the deterministic layer exists. Slice 2 adds Jev and the
  auditor. Slice 3 runs the audit automatically at every Shaping stop.
- **Exact checks only.** These are the recurring Draft misses that Kogen code
  can check exactly:
  - Build's own admission predicates, all of them, never only the first;
  - the test-reliability ledger;
  - controller-read paths;
  - an unselected edited live owner;
  - an unproven or over-broad paid target;
  - stale anchors;
  - the title and commit-subject format;
  - an unparseable package;
  - prior failures of the same Intent, as advisory.

  Each finding has a stable id, and a false positive can be disputed in
  `questions.md` `## Dispositions`, except for the mechanical set.
- **Short commit subjects** (package directions 20, 28 and 29). `intent.yaml`
  gains an optional `commit_subject`. Build commits it as the publication
  subject, with the unchanged `Kogen-Intent-ID` and `Kogen-Intent` trailers
  and no body. A package without it (every package approved before this
  change) is committed with its `title`. The audit requires `commit_subject`
  on every Draft it sees (`commit-subject-format`).

## Starting point (exact; the Developer does not redesign)

Start from develop `e65392cf`. The Candidate hunks of the non-converging
Builds are in `evidence/`:
- `evidence/candidate-qbOzahf8-f4819c37-codex.diff`: the whole codex Candidate;
- `evidence/candidate-ZujYgSGt-555d0af3.diff`: the older Claude-route
  Candidate;
- `evidence/candidate-*-slice.diff`: this slice's files only.

`evidence/CANDIDATE.md` says, file by file, whether each hunk applies at
`e65392cf` (checked with `git apply --cached --check` against a temporary
index of `e65392cf`, probe P3), and what to keep, trim or fix. Use the hunks as the starting code,
then make the tests below pass. Summary:

- These qb hunks apply unchanged:
  - `lib/kogen/build/verification_plan.ex` hunk 1 only (qb slice diff lines
    1-96), adding the public `proof_errors/4` beside the unchanged `build/4`.
    **Drop hunks 2 and 3**: they add `require_no_extra_targets/2` to
    `validate_declared_targets/2`, a new Build admission refusal for any extra
    `check`, `live-*` or `cold-*` Make target. That is a Build change this
    Intent does not make. The trimmed hunk applies at `e65392cf`;
  - `lib/kogen/verification_policy.ex`, adding `controller_paths/0`;
  - `lib/kogen/build.ex`, exporting `VerificationPlan` from the Boundary;
  - `lib/kogen/shaping_audit/{finding,materialization,package,report,deterministic}.ex`;
  - `lib/mix/tasks/kogen.audit.ex`;
  - `test/support/shaping_audit/fixture.ex` and the fixture Drafts;
  - `test/kogen/shaping_audit_checks_test.exs` and
    `test/kogen/shaping_audit_task_test.exs` as a starting point only: the
    test list is closed (see "Tests and fixtures").

  Probe P1 (`evidence/probe-candidate-at-3531023d/RESULT.md`) applied the
  whole qb Candidate to `3531023d`. Every checks and task test passed except
  the README test, whose README hunk was not applied. Probe P3
  (`evidence/probe-candidate-at-e65392cf/RESULT.md`) applied it to
  `e65392cf`: `mix format --check-formatted`, `mix compile
  --warnings-as-errors --force`, `mix credo --strict` and the test-compile
  stage all pass on the qb files.
- These files need trimming to this slice:
  - `lib/kogen/shaping_audit.ex`: the qb version wires all three layers and
    the Stop hook. Here it runs only the deterministic layer, parses
    `--route`, `--status` and the slug, and has no `--auditor` or
    `--stop-hook`. It has no asking state: remove `Questions.state/1`, the
    `state` context and report keys, `readiness(:asking, …)` and the
    `questions` summary (`Questions.entries/2`). It calls only
    `Questions.parse/1` and passes its `dispositions` to
    `Finding.apply_dispositions/2`.
  - `lib/kogen/shaping_audit/deterministic.ex`: remove the `run(%{state:
    :asking})` clause and every `Questions.findings/2` call. It never calls
    `Kogen.ShapingAudit.Questions`.
  - `lib/kogen/intent.ex`: take only the `commit_subject` hunks (the
    `intent` type, `optional_string/2`, `normalize_intent/2`, the `read/2`
    doc), not the `auditor` hunks.
  - `lib/kogen/harness.ex`: take only the Boundary export of `Claude` and
    `Codex`, so the audit can read `Kogen.Harness.Claude.settings_path/0`.
- **New file `lib/kogen/shaping_audit/questions.ex`**, written for this slice
  (qb's `questions.ex` is slice 2's and is not taken). It reads only the
  `## Dispositions` section of `questions.md` (see "Disputes" below) and
  exposes `parse/1` returning `%{dispositions: %{id => %{"kind" =>
  "not-a-defect", "reason" => reason}}}`. It has no other section, state,
  entry or finding function. Slice 2 extends this file.
- The publication subject hunk is in the Zuj diff (lines 161-162, hunk 2 of
  `lib/kogen/build.ex`). It applies by itself at `e65392cf`. The subject is
  `Map.get(ctx.intent, :commit_subject) || ctx.intent.title` inside the private
  `finish_publication/4`, at the `Kogen.Git.commit_staged/3` call at
  `lib/kogen/build.ex:2742` (in `finish_publication/4` at :2732). The qb Candidate never made this change (its
  `build.ex` hunk only exports `VerificationPlan`), so a qb-only port loses
  the feature.
- `test/kogen/commit_provenance_test.exs`: the Zuj hunk applies. It adds the
  published-subject assertions.
- The candidates' ledger rule and fixture use a ledger format that no longer
  exists (`maintained_sources`, `source_sha256`). Replace them with the
  ledger-by-name contract below.
- The candidates' `prior-failures` reads top-level `build_id` and `signature`
  keys, which real tracking records do not have. Replace it with the
  real-record shape below.
- Run `mix format` before ending every turn. Cycle 1 of Build qbOzahf8 failed
  `mix format --check-formatted` on `lib/kogen/build/verification_plan.ex`.

## Exact decisions

- **Materialization.** Each audit makes a private `0700` directory
  `<system tmp>/kogen-audit-*`. It holds a `git clone --local --no-checkout`
  of the checkout, with `HEAD` checked out and the package's files added.
  Every rule except `prior-failures` reads only this directory. The directory
  is removed after every run, including failures.
- **Revision.** The revision is a lowercase-hex SHA-256 over the package's
  sorted relative paths and file bytes, taken under an `lstat` walk. A
  symlink, FIFO or other non-regular entry is refused, naming it (exit 2),
  before any file is read.
- **Report** (`schema_version: 1`). `report.json` has these keys:
  - `schema_version`, `slug`, `package` (relative path), `revision`, `head`
    and `route`;
  - `layers`, which is `{"deterministic": {"status": "ok" | "unavailable",
    "reason": …}}` in this slice;
  - `findings`: a list of `{id, rule, layer, scope, severity, disputable,
    scenario, paths, message, disposition}`;
  - `readiness`: `ready` or `not_ready`.

  `ready` means that every layer is `ok` and no blocking finding is open. A
  finding stays open unless it is disputable and disputed. `report.md` is the
  same summary for a reader. Slice 2 raises `schema_version` to 2 and adds
  layers. An unknown `schema_version` counts as `missing`.
- **Finding ids** are stable: the rule id, or `<rule> <subject>` when a rule
  can fire more than once (`stale-anchor cited_bytes`). **Disputes:** a
  `questions.md` `## Dispositions` line `<id>: not a defect — <reason>` clears
  a disputable blocking finding. The line may start with `- `; the dash
  before the reason may be `—`, `--` or `-`; the id may be backticked. The
  section runs to the next `##` heading. The disposition is stored on the
  finding as `{"kind": "not-a-defect", "reason": <reason>}`. Any other line
  (including `<id>: fixed — …`, slice 2) is ignored in this slice. The mechanical set cannot be disputed:
  - Build's admission predicates: `unguarded-affected-path`,
    `proof-selector-missing`, `unsupported-selector`, `unknown-target`,
    `verified-by-invalid` and `paid-reason-malformed`;
  - `ledger-closure`, `controller-read-path` and
    `edited-live-owner-unselected`;
  - `title-format`, `commit-subject-format` and `package-invalid`.

  `ledger-row-update-unstated`, `paid-path-unproven`, `paid-target-overbroad`
  and `stale-anchor` are disputable.
- **Ledger rules**, per the landed ledger-by-name contract
  (`scripts/check/README.md:221-226` "binds each cataloged test declaration to
  its test by name"; `test/support/test_reliability_catalog.ex:36` stores only
  `id disposition scenario implementation wrong_control_locator resolution`
  in the remediation file). The catalogued files are the committed ledger's
  `declarations[].file` values.
  - `ledger-closure` (mechanical) fires when a scenario's `affected_paths`
    include a catalogued file and `priv/kogen/test-reliability.yaml` is not
    guarded.
  - `ledger-row-update-unstated` (disputable) fires when a scenario deletes
    a catalogued test, or adds a ledger row, and the Draft does not guard
    both ledger files. The finding names the missing file. A scenario
    deletes a catalogued test when one sentence of its `given`, `when`,
    `then`, `wrong_result`, `evidence` or `tests` holds the exact `declaration`
    string of a catalogued row in an affected file, together with a whole
    word from {delete, deletes, deleted, deleting, remove, removes, removed,
    removing}. Sentences are split on `.`, `;` and newlines. A scenario adds a
    ledger row when one sentence holds "ledger row" or "catalog row" together
    with a whole word from {add, adds, added, adding}. Word matching ignores
    case (`Delete`, `REMOVED` and `Adds` count); the `declaration` string and
    the phrases "ledger row" and "catalog row" are matched as written, except
    that the phrases also ignore case. A rename never fires:
    the same sentence with {rename, renames, renamed, renaming} and no
    deletion word gives no finding.
  - Both messages state the contract. Editing a test's body, or adding a
    test, needs no row change. Renaming a catalogued test means editing its
    row's `declaration` by hand in `priv/kogen/test-reliability.yaml` only.
    The remediation file changes only when rows are added or deleted.
    Guarding either file is harmless. No message names a script.
- **Controller-read paths** are the union of `VerificationPolicy.controller_paths/0`
  and `Kogen.Harness.Claude.settings_path/0`. `controller_paths/0` returns
  exactly what `preflight/2` reads: `.codex/hooks.json` and
  `.codex/hooks/verification_policy.py`. It never returns `check.sh`,
  `stop_runner.py` or `environment.py`. No path is a string literal under
  `lib/kogen/shaping_audit`. `.kogen/config.yaml` is not on the list: the
  running controller reads it once at Build start and freezes the role
  assignment.
- **Paid rules.**
  - `paid-path-unproven`: a scenario selects a provider-backed target, and
    the Draft's `affected_paths` include that target's catalog `owner` or a
    repository path listed in its catalog `prepare` command (an element of the
    `prepare` argv that equals an affected path). It fires when no package
    file `evidence/probe-*/RESULT.md`, and no regular file at any depth under
    `evidence/proving-run-*/`, contains the target's name. qb's rule checks
    only the owner and only `probe-*/RESULT.md`; add both other branches.
  - `paid-target-overbroad`: a scenario's `proof.paid_target` is selected by
    no other scenario of the Draft, and every one of its `affected_paths` is
    under `test/support/`. The message's default fix is "introduce the
    cheaper check (offline test, then an offline replay of retained real
    provider evidence, then a minimal live smoke)". It never asks the
    Shaper.
  - `edited-live-owner-unselected`: an affected path is a provider-backed
    target's `owner`, and no scenario selects that target.
- **Stale anchors.** For every `path:line` citation and every backticked
  identifier in the package files, compare `git show <shaped_against>:<path>`
  with `HEAD` inside the materialization. A cited line whose text changed is
  `stale-anchor <path>:<line>`. An identifier that existed at `shaped_against`
  and is gone at `HEAD` is `stale-anchor <identifier>`. An identifier that
  exists at neither is new in the Draft and is never flagged. If
  `shaped_against.head` is not a local commit, the finding is
  `stale-anchor-baseline-unavailable`, which tells the Controller to
  re-verify its citations and update `shaped_against` itself.
- **Title rules.**
  - `title-format` fires on more than 50 characters, a trailing period, or a
    lowercase first letter.
  - `commit-subject-format` fires on a missing `commit_subject`, more than 72
    characters, a trailing period, a lowercase first letter, or more than one
    line (the value, after trimming a trailing newline, contains `\n`; the
    message says "more than one line"). qb's rule lacks the line check; add
    it.
  - Each finding names every failed rule. Imperative mood is not checked.
- **Prior failures** (advisory). This is the one read outside the
  materialization. It reads the checkout's
  `.kogen/runtime/scenario-tracking/*/record.json`, **not** the
  `failure-report.json` that Builds write beside it since `e65392cf`
  (`lib/kogen/build/failure_report.ex`). Decision: keep `record.json`. Every
  retained Build has one, including every Build before `e65392cf`, which has
  no failure report; its `attempts[].failure` is still a string
  (`lib/kogen/build.ex:2129`, `:2334`); and one reader is simpler than two
  with a fallback. `failure-report.json` is never read:
  - only the newest 200 by mtime;
  - each `stat`ed first and skipped unread when over 32 MiB;
  - an unreadable or undecodable record is skipped and counted.

  It uses the real record shape: `intent.id` equals the Draft's `id`,
  `status` is `"failed"`, and the Build id is the record's directory name.
  The signature is the last failed attempt's `failure` string, cut to 200
  characters. The finding lists every matching Build id with its signature.
- **Repository validity.** The deterministic layer calls
  `Kogen.Build.VerificationPlan.load/1` on the materialization (the committed
  catalog and Makefile). Any `{:error, reason}` it returns (for example a
  catalog target with "no ordinary Make rule", a malformed catalog, or an
  unreadable Makefile) gives one finding `repository-invalid`: scope
  `environment`, blocking, not disputable, message `reason`, no paths. The
  layer's status is then `unavailable` with `reason`, so readiness is
  `not_ready` and the exit is 1. No catalog rule runs (proof,
  `controller-read-path`, `edited-live-owner-unselected`, both paid rules).
  The finding is recognised by the `{:error, _}` result alone, never by
  matching the message text. The other rules (ledger, stale, title,
  `package-invalid`, `prior-failures`) still run.
- **Refusals** (exit 2, no report, no materialization, no package read):
  - `KOGEN_ROLE` is `developer`, `reviewer`, `expert` or `auditor`;
  - `.kogen/build.lock` exists;
  - the slug exists in both `drafts/` and `approved/`;
  - the slug exists in neither;
  - a bad argument.

  `KOGEN_ROLE=shaper` and an approved-only package run normally. Slice 3
  changes the Shaper case: inside a Shaping session, the command prints the
  hook's status instead.
- **`commit_subject` in `Kogen.Intent`.** It is optional. When present it must
  be a nonblank string, otherwise the reason is `commit_subject must be a
  nonblank string`. When absent the value is `nil`, and completed packages
  keep loading. The audit, not the Build, requires it on new Drafts.

## Tests and fixtures

Offline only. `test/support/shaping_audit/fixture.ex` builds the git fixture
repository described in the header of `scenarios.yaml`. Its ledger is in the
landed format: JSON with `declaration_count` and `declarations`. The one row
is `{id: "test-a-test-exs:t001", file: "test/a_test.exs", declaration: "a
works", …}`, and the remediation file has the matching `resolved` row. Its
tracking records are in the real record shape. It commits a
`.kogen/config.yaml` with `default_route: codex` and a second route `other`.
`Fixture.repo!/1` options: `catalog_mismatch:`, `oversized_record:`,
`prepare:` and `compiled:` (the header says what each changes).

**The test list is closed.** `test/kogen/shaping_audit_checks_test.exs`
contains exactly the tests A1-A7, B1-B7 and C1-C6, and
`test/kogen/shaping_audit_task_test.exs` exactly D1-D8 (D3 is one `for` over
the four roles, so four tests). Each ExUnit test name is exactly the quoted
string in the scenario's `tests` entry. The label (`A1`, `D3`) is **not**
part of the name; it may appear in a comment above the test. E1 is one new
test in `test/kogen/intent_test.exs`; E2 extends the existing test in
`test/kogen/commit_provenance_test.exs` under its unchanged name. Every
other qb test in the two files is removed, not kept beside the list. In
particular:
- "ledger-flawed: an unguarded maintained-source edit blocks with
  ledger-closure" and "ledger-unstated: a guarded ledger with no refresh
  command blocks with ledger-row-update-unstated" (the removed ledger
  format; B1 and B2 replace them);
- "a committed catalog that does not match the committed Makefile gives
  repository-invalid instead of the catalog rules" (qb's extra-Make-target
  case; A6 replaces it);
- "prior_failures/3 is bounded: an oversized record is never read" (the old
  record shape; C5 covers the bound);
- "asking state: a missing scenarios.yaml is never package-invalid, and only
  question rules run" (slice 2);
- "preservation: selective_verification_targets_test.exs and
  verification_policy_test.exs still pass" (a nested `mix test` in the
  checkout from an `async: true` test, which contends for locks and `_build`
  under the gate, lesson 25; both files are already proof selectors of
  `audit-mirrors-build-admission`);
- in the task file, the fake-layer tests on the `demo` package that assert
  `state`, `jev` or `auditor` keys, "inside a Shaping session a manual run
  audits nothing and prints the hook status", "inside a Shaping session,
  with no hook-state.json yet, the status falls back to the newest report
  directory", both "end to end with the real layers…" tests and "a route
  named ../x writes its auditor record only inside auditor/, named by the
  route's hash" (slices 2-3). Every D test runs on `Fixture.repo!/1` and the
  `complete` Draft.

Tests never read `.kogen/intents/**` of the real checkout, because a package
moves on landing. They run the entry function and the mix task in
`Kogen.IsolatedCase` fixture checkouts. They reproduce any concurrency
failure under the whole offline gate, never "passes in isolation" (lesson
25).

Every `main/2` call in the tests passes `env: %{}` (or `%{"KOGEN_ROLE" => <role>}` where the role refusal is under test),
and D7 passes `[{"KOGEN_ROLE", nil}]` to `Kogen.CompiledFixture.mix_task!/3`. Reason: the Codex harness sets `KOGEN_ROLE`
(`developer`/`reviewer`) in the Developer's and Reviewer's own sessions (lib/kogen/harness/codex.ex), and only the gate's
verification runner removes it (lib/kogen/build/verification_runner.ex), so tests that inherit the environment would be
refused (exit 2) when a role runs them but pass in the gate.

The Dispositions parser splits each line at the first `: not a defect` (ids may contain `:`, e.g.
`stale-anchor lib/a.ex:3`); C2 or a B test covers an id containing `:`.
