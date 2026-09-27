# Rework stray paths instead of stopping

Shaped against develop 3ab70dce (build-reliability landed at 82ac4351). Citations into lib/ name functions, not lines
(shaping-quality also edits build.ex; re-derive after it lands); test citations are lines at 3ab70dce.

## Why

After every Developer turn, `Kogen.Build.post_developer_inputs_unchanged/1` runs `approved_unchanged/1` and
`Kogen.Build.GuardedPaths.check/2`; any stray path, any Approved-copy entry and any change to control's shared git files
stops the Build as `integrity`. Four Builds died that way on 2026-09-26 alone: stray Mix lock dirs (lesson 20), a `.pyc` in
the Approved copy (lesson 21), Claude Code's exclude block and VS Code's `vscode-merge-base` in control's shared git files
(lessons 19, 22). Lesson 21's `.pyc` was found at publication, which this Intent still stops (see Outcome); moving the
check to the turn it happens is what makes it reworkable.

## Outcome

- **Rework, not stop.** After a successful Developer turn, (a) untracked or changed paths outside the guards and (b)
  entries ADDED to the Candidate's Approved copy (classified inside `approved_unchanged/1` before the guard, only at the
  Developer handoff) resume the SAME Developer session (`resume_developer/3`). The resume sets `developer_prompt` to the
  rework prompt and `provider_retried: false`, as `resume_after_failed_cycle/6` does, so a provider retry
  (`retry_developer/5`) resends the rework prompt. The prompt lists the offending paths with untracked directories
  collapsed to their topmost new directory (e.g. `mix_lock_user501`, `.kogen/intents/approved/<slug>/evidence`); says
  to delete untracked paths and to restore a modified or deleted tracked file with the exact command
  `git show HEAD:<path> > <path> && chmod <mode> <path>`, `<mode>` being `644` or `755` from the file's HEAD tree mode
  (100644 or 100755), which also undoes a mode-only change, because `git checkout`/`git restore` write the worktree
  index under control's `.git`, which the write boundary denies (`Kogen.Build.WriteBoundary.forbidden/4`); says that
  deleting the listed added Approved entries restores the frozen package (priv/kogen/prompts/developer.md's
  "read-only" line is updated to say so); and forbids git clean/stash/reset/checkout/restore of the tree and TMPDIR
  overrides. The stop message keeps listing files as today.
- **The work turn's notes reach Jev and Review.** A turn that ends in a guard rework is not verified, so its notes
  would otherwise be replaced by the cleanup turn's. The controller keeps the notes of each turn that ended in a
  rework (in the order they were written) and, when a later turn passes the guard, `verify_turn/5` uses as that turn's
  notes the kept notes followed by the current turn's, each part headed by a controller line `[Developer notes, turn
  that ended in guard rework <k>]` or `[Developer notes, turn that passed the guard]`; the kept notes are then cleared.
  Jev reads that combined text once (as today, one reading per verified turn), and the attempt's `developer_notes`,
  the packet's `developer_notes` and a `cannot_comply` quote all carry it through the existing code. Each
  `guard_violations` entry also records its own turn's notes (`notes_record/1`), so a Build that stops as
  `guard-violation` keeps them.
- **Provider failure in a rework turn: guard first, then retry.** `settle_transport_failure/4` keeps today's order: the
  guard check runs before any provider retry, and a failed turn that leaves any violation (reworkable or terminal)
  stops with today's guard message, category `integrity`, with no provider retry and no further rework. Only when the
  failed turn leaves the guard clean does a retryable marker lead to `retry_developer/5`, which resends
  `ctx.developer_prompt` (the rework prompt) to the same session; a provider retry is not a guard rework and leaves the
  guard reworks left unchanged.
- **Budget.** A dedicated guard-rework limit of 2 per attempt: a module attribute in `Kogen.Build` (`@guard_reworks 2`)
  with a comment saying what it bounds; not a config key and not `offline_retries`. Reworks are counted per attempt in a
  `guard_violations` list in the attempt record (one entry per occurrence including the exhausting one: cycle, the
  complete path list exactly as the prompt listed it, and that turn's `developer_notes`).
  The prompt states guard reworks left. When spent: stop with category `guard-violation`. A guard rework runs no
  verification cycle, so `offline_retries`, `offline_failures` and every other `Kogen.Build.Verification` count stay
  untouched (verification.ex is not edited). test/support/workspace_fixture.ex keeps its `offline_retries: 4` default.
- **Review packet.** `guard_violations` is a new top-level key of the review packet (`Kogen.Build.ReviewPacket`, `[]`
  when none, `schema_version` stays 1), bounded like the packet's other fields. It holds one object per entry of the
  latest attempt, in order (at most `@guard_reworks` reach Review; the exhausting one stops): `cycle`, `path_count`,
  `paths`, and `sha256`, `byte_count` and `locator` (`/attempts/<i>/guard_violations/<k>/paths`) of the full path
  list's canonical JSON. `paths` is the longest prefix of whole paths, never a cut path, whose canonical JSON array
  fits a new per-profile `guard_paths` cap in `@profiles` (4_096, 2_048, 512, 0). When the prefix is shorter than the
  list the object gains `"truncated": true` and `omitted` gains the existing `omission/4` item (field
  `/guard_violations/<k>/paths`). Entry notes are not repeated (the packet's `developer_notes` carries them). The last
  profile inlines no paths, so the field is a fixed size there and never makes packet construction fail; the full list
  stays in the record. test/kogen/review_packet_test.exs's exact key set gains it, and priv/kogen/prompts/reviewer.md
  tells the Reviewer what it means: paths the controller made the Developer delete or restore before verification; a
  truncated list is complete in the record at its locator; not a finding and not verification; check that the Candidate
  does not still depend on them.
- **Shared git files are control's, not the Candidate's** (lessons 19, 22). `GuardedPaths.check/2` returns
  `{result, snapshot, env_events}`: `result` is `:ok`, `{:rework, paths}` or `{:stop, category, message}`; `snapshot` is
  the refreshed snapshot; each event is `%{file: ".git/config" | ".git/info/exclude", before: sha256, after: sha256}`.
  The refresh replaces only those two files' event-detection bytes; the head tree, ignored-file manifest and Build-start
  exclude bytes stay. The Build records the events under the attempt's `environment_events` and puts the refreshed
  snapshot in `ctx.guarded_snapshot` in ALL three callers of `post_developer_inputs_unchanged/1`: `verify_turn/5`,
  `receive_developer/4` (the failed-turn clause) and `settle_transport_failure/4` (including before
  `retry_developer/5`). An event alone never stops the Build and is never reported twice. Roles cannot write those
  files (write-boundary grants).
- **Exclude hiding is terminal.** After a `.git/info/exclude` environment event, at that handoff and every later one,
  any Candidate path whose ignored state changed since capture, guarded or not, stops the Build with category
  `git-policy` and the message "Control's .git/info/exclude changed the ignored state of Candidate paths: <paths>".
  Ignored state changed means the current exclude ignores the path and the Build-start exclude did not, or the reverse
  (e.g. a new file the added rule hides); the Candidate's own `.gitignore` files apply under both, and volatile paths
  stay excluded as today. Such a path would otherwise be verified in the worktree but left out of the Candidate id and
  the publication commit (`git add -A`, `Kogen.Git`).
- **Terminal, with explicit categories passed to the stop:** an unguarded change to the Candidate's ROOT `.gitignore` →
  `git-policy` with today's stray-path message ("Candidate changed paths outside Approved guards: .gitignore"); a
  `.gitmodules` change → `git-policy` with today's config message ("Git configuration or ignore policy changed during
  Developer turn"); a nested `.gitignore` (e.g. `.pytest_cache/.gitignore`) is an ordinary reworkable stray path.
  Unguarded changes to `.codex/hooks/**`, `.codex/hooks.json`, `.codex/config.toml`, `.claude/settings.json`,
  `.claude/hooks/**`, `.claude/agents/**`, `.claude/commands/**`, `.claude/skills/**` → `protected-path`, with today's
  message "Candidate changed paths outside Approved guards: <paths>" (candidate_verification_test.exs:161-168 asserts
  that prefix for an unguarded `.codex/hooks/**` tamper and passes unedited); modified or deleted Approved-copy
  entries, and ANY Approved-copy change found outside a Developer handoff (check, target, Review, publication —
  approved_mutation_test.exs stays as is) → `integrity`. `resume_after_failed_cycle/6` runs `approved_unchanged/1`
  after each failed verification cycle and before resuming, so an Approved-copy addition made by a check stops as
  `integrity` instead of being blamed on the Developer. A failed Developer turn with a violation, including a
  provider-marked failure → today's guard message, category `integrity`, zero resumes. Terminal wins over reworkable
  in the same turn. The new categories are passed explicitly; the existing prefix table keeps classifying the other
  stop messages until durable-builds-and-failure-reports replaces it.
- **Tests and ledger.** `test/kogen/guarded_paths_test.exs` (shared-file cases) and `test/kogen/build_workspace_test.exs`
  (the Build stop on a `.git/config` change) are rewritten to the environment-event rule; only Candidate `.gitmodules`
  changes keep the config message. The test-reliability ledger binds tests by name (82ac4351); rows are edited by hand
  only if a bound test is renamed.
- **README.** The retry-budget paragraph (README.md:458-462) gains one sentence: stray paths after a Developer turn
  resume the same session up to 2 times per attempt (fixed, not configurable, not `offline_retries`), then stop as
  `guard-violation`; hook/agent config changes stop as `protected-path` and Git policy changes as `git-policy`.

## Non-goals

- Making the Approved copy read-only; changing what is guarded, volatile or ignored; any change to verification.ex or
  to `offline_retries`.
