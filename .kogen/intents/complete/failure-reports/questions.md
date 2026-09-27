# Questions and choices

No open questions. Decisions: DIRECTION rules 37, 42, 43, 44, 49, 51; lessons 17, 19-25. Numbers in brackets are the
original package's Assumed items.

## Assumed

1. Reports are the only store of counts; there is no counter file. [1]
   Reason: rule 49 counts "on an unchanged package" and "across Intents"; the reports carry both keys and survive a
   restart. build-breakers reads them.
   Undo: add a per-project counter file.
2. The report keeps the existing vocabularies. `category` is the owner-record string and `stop_class` the attempt
   value, both unchanged. `class` repeats `environment` and `provider`, so there is no `provider_down`. [3]
   Reason: build-reliability already owns `provider` and `environment`; a second name for either would be a second
   vocabulary (original round 1, Opus).
   Undo: rename in the one table, and update the tests existing-expectations-kept lists.
3. Each stop's category is decided once and used for the owner status, the report and the message. The only changes
   are readiness failure → `environment` and login rejected → `environment`. The shape: an explicit `stop_category`
   detail where the call site knows the category, fa48e817's `stop_category/1` table (unchanged) for the rest,
   evaluated once in `stop`. [4, 17, reshaped twice]
   Reason: the original fixed a stricter mechanism (`stop/4` with no default argument, a literal category per call
   site), which the Reviewer blocked on as shape (F1). Round 1 of this package left the mechanism open, and Opus
   judged that a Developer couldn't tell what to change and a Reviewer could reopen F1. The chosen shape is what
   fa48e817 already half-does, so it is the smallest change that has one classifier (rule 44).
   Undo: restore the original's `stop/4` requirement.
4. A login rejection (Claude 401 / `authentication_failed`; Codex 401 or refresh failure) is `environment`, with the
   binding's login command, in Developer turns, Reviews and paid targets. It is never retried, and no credential code
   changes (lesson 24). [5]
   Reason: a revoked token fails every turn; retrying burns time, and D1 protects login state. F6 closed with the
   starting point's marker and login command.
   Undo: drop the login marker and its three callers.
5. Refusals before the tracking record exists are not Builds: they write no report and never count. [6]
   Reason: they spend nothing and already fail loudly, and build_preconditions_test.exs asserts that no tracking
   record exists (original round 1, Sol).
   Undo: write refusal reports into a separate directory.
6. The class table is the one in INTENT.md. `provider-failure`, `publication-failed` and `accepted-unpublished`
   count as environment. `integrity`, `review-failure` and the guard categories count as item. [8]
   Reason: a harness crash with no marker, or control moving under a Build, is not the package's fault; a Developer
   write to the Approved copy or a malformed Review repeats on an unchanged package.
   Undo: move a category to another row.
7. Lesson 25 is fixed in the prompt: the rework prompt carries `first_failure`, `error_head`, a reproduction and
   "Passes in isolation is not acceptable". The frame gains an optional `reproduce` field, which is never hashed. The
   reproduction is the stage's own command with the `MIX_ENV` offline.py's `run_stage` gives it; without a frame
   value, the generic line names the command `make <target>` runs, and says the controller runs `make <target>`
   itself. [12]
   Reason: the Developer can't run `make <catalog target>` (the Bash gate guard), and the prompt's header already
   says not to run the targets, so the reproduction must be the stage's own command at its normal concurrency and in
   its own environment (`dev` for every non-test stage, Opus round 1).
   Undo: drop the `reproduce` field and keep the generic line.
8. The failed cycle's signature is saved in the attempt's `cycle_signatures` before the resume, not only at
   settlement. Settlement is unchanged. [15, part]
   Reason: `failure_signatures` is written only by `settle_verification/3`, which a pending cycle never reaches, so
   without this a real Build's prompt has no signature (F5). Leaving settlement alone keeps every digest and
   `repeated` flag.
   Undo: drop `cycle_signatures`; the prompt then derives the signature from the cycle each time.
9. The report is written by temp file and rename, never replaced, after the record's final update and before the
   owner status. Never replaced means a hard link that fails on an existing target, or an existence check and rename
   under the control's Build lock. [new, F1]
   Reason: F1; a reader (build-breakers, build-continuation, `mix kogen.candidates`) must never see a partial report,
   and `record_sha256` binds the continuation to the exact record. Writing it before the owner status means a crash
   between the two leaves the owner `running`, which build-continuation's reconcile picks up.
   Undo: write in place and accept partial reads.
10. No paid target; every proof is offline. [13, part]
    Reason: DIRECTION rule 49 ("no paid target"); the login paths are proven with a real recorded 401 excerpt replayed
    through the fakes. Claude logins are revoked (rule 51).
    Undo: add a live target and its guarded paths.
11. No redaction of `error_head` or `reason`. [14]
    Reason: rule 42.
    Undo: pass report text through a redactor before writing.
12. The recorded detail key stays `stop_category`; the Candidate's rename to `category_override` is not taken. [new]
    Reason: the key is already written into record.json attempts at fa48e817 (guard and integrity stops), so a rename
    changes recorded data for no behaviour gain, and later readers (build-breakers, build-continuation) would need
    both names.
    Undo: rename the key everywhere it is written and read, in one change.
13. The Build's error message names the category (`; category: <category>; failure report: …`). [new]
    Reason: without it no test can show that the message and the report agree (Opus round 1, Blocking 2). Existing
    tests match messages by substring or pattern, so an added field breaks none.
    Undo: drop the `category:` field and assert agreement only between the owner status and the report.
14. A paid target's login rejection sets the cycle failure `reason` to "make <target>: <harness> login rejected (401)
    (class environment); run `mix kogen.<harness>.login`" (unscoped: verification.ex has no bindings). The Build's
    stop reason for it replaces "environment failure before any provider-backed target", which would be false, with
    the same text plus "; no retry was spent", using the Build's binding for the tail's harness. [new]
    Reason: the test (`F.run_cycle!`) sees only the cycle, so the reason field must carry the text; the Build's message
    must be truthful and name the scope-correct command, as the Developer and Review messages do.
    Undo: keep today's environment wrapper text and put the login command only in the report's `next_command`.
15. The login command follows the tail's harness, not the role's. [new]
    Reason: the credential that was rejected is the one the tail came from; on the codex route a Review or paid
    target printing a Claude tail needs `mix kogen.claude.login`.
    Undo: derive the harness from the role's binding.
16. The Candidate diff is a reference to copy from, not a patch to apply whole, with an explicit take / drop / fix list.
    [new]
    Reason: its later-slice code sits inside the hunks this package keeps (failure_report.ex, build.ex,
    kogen.candidates.ex), so "keep the hunk" carried build-continuation code in (Opus round 1, Blocking 1).
    Undo: apply the diff whole and list only the hunks to revert.

## Audit

- Split 2026-09-27 at fa48e817 from the approved `durable-builds-and-failure-reports` (approved at f1d176b0, moved to
  drafts/ as a superseded reference). Two Builds of it ended with F1, F2, F3, F4, F5 and F7 open. It was too big for
  one Build (10 scenarios, 28 guarded paths, three features at once), and it named internal functions and arities
  (`stop/4`, `verification_failure_prompt/4`, `FailureReport.reconcile/1`, …), so the Reviewer judged shape instead
  of behaviour. The split keeps every behaviour and states it as observable outcomes (rule 43: reshaping technical
  detail needs no Shaper). There is no UX change.
- What moved here: the report (original every-stop-has-a-report, minus `budget_state`, `continuable`, `continues`,
  `published`), login-rejected-is-environment, rework-prompt-inlines-first-failure (minus the fresh Build's first
  prompt), the report lines of `mix kogen.candidates`. Original risks self-hosting, categories-preserved,
  readiness-blind-to-revocation, login-marker-scope, and the report part of overlapping-drafts. Assumed 1, 3, 4
  (reshaped), 5, 6, 8, 12, 13, 14, 15 (the signature part), 17 (reshaped).
- What moved out: breakers and the fresh Build's first prompt → build-breakers; continuation, reconcile, refusals,
  publication crash, `budget_state` and the interrupted categories → build-continuation.
- Existing ledger rows in touched files, checked by name at fa48e817: 18 in controller_handoff_test.exs and 2 in
  build_preconditions_test.exs. None is renamed.
- Claims checked at fa48e817: the XfjCRM76 record's sha256 and final `result` event; the excerpt wrapper
  (provider_outcome_test.exs `fixture/1`); ScriptedBuildFixture's `fail_first`, `provider_fail`, `provider_tail` and
  `developer-invocation-<n>-prompt`; fake_claude's `FAKE_CLAUDE_LOGGED_OUT`; `stop/3`, `stop_category/1`,
  `record_failure/2`, `refuse_publication/4`, `resume_after_failed_cycle/6`, `verification_failure_prompt/3`;
  `FailureHandoff.render/1`'s first line and 24,000-byte bound; offline.py's `failure_signature_frame` and
  `--signature-frame`. The Candidate diff passes `git apply --check` at fa48e817.
- Opus review, round 1 (2026-09-27, frr/opus.md): not ready.
  - Blocking 1, later-slice code kept in the diff's hunks: INTENT.md "Starting point" rewritten as take / drop / fix,
    with the diff as a reference; references.yaml matches. It drops reconcile/1, the interrupted,
    publication-interrupted and session-lost rows, the continues, budget_state, published and continuable fields,
    refuse_publication's published detail, the "written by the next mix kogen.build" text and the reconcile call in
    run/3 (Assumed 16).
  - Blocking 2, category "decided in two places" without a closing test: replaced by the explicit / one-function /
    evaluated-once shape; `stop_category` key kept; readiness made explicit; the message names the category, and a
    test asserts owner status, report and message agree for (a), (c) and a Claude login (Assumed 3, 12, 13).
  - Blocking 3, paid-target login underspecified: the cycle failure `reason` text is exact, the command follows the
    tail's harness, and the Build's environment wrapper is replaced for this case (Assumed 14, 15).
  - Non-blocking, all folded in: the Candidate's divergences (build_id, slug and intent_id locations, seconds in
    stopped_at, same_signature_count keying, absolute record path, no harness in the login message, offline.py's
    `make check` for non-test stages, the handoff's `make check` fallback, the extra primary_lines line); no-clobber
    publication (Assumed 9); the Reproduce line made consistent with "do not run them yourself" (Assumed 7); the
    login command following the tail (Assumed 15). `existing-expectations-kept` keeps no `proof.base`.
- Opus round 2: ready; wording nit (Reproduce fallback) applied.
