# Questions and choices

No open questions.

## Assumed

1. Budget = a dedicated `@guard_reworks 2` per attempt in Kogen.Build, not build-reliability's `offline_retries`
   (replaces round 3's choice; verification.ex untouched).
   Reason: `offline_retries` belongs to offline verification failures with its own `offline_failures` and
   `offline_exhausted` accounting (verification.ex); sharing the integer would spend or hide it (round 4, Astra).
   Undo: replace the attribute with a config key and its validation in `Kogen.Intent`.
2. Terminal: an unguarded root `.gitignore` change and any `.gitmodules` change (`git-policy`); unguarded hook
   registration/scripts (`.codex/hooks/**`, `.codex/hooks.json`, `.codex/config.toml`, and the loaded `.claude` config
   only: `settings.json`, `hooks/**`, `agents/**`, `commands/**`, `skills/**`); modified/deleted Approved files; any
   Approved change outside a Developer handoff; a failed turn with a violation.
3. Files ADDED inside the Approved copy are reworked like any stray path (lesson 21); read-only copy dropped (review round 1).
4. No config key and no "seam for later" (§1.16).
5. Shared control .git/config and .git/info/exclude changes are `environment` events, not stops (lessons 19, 22; moved
   here from parallel-builds).
6. `GuardedPaths.check/2` returns `{result, snapshot, env_events}` and every caller of
   `post_developer_inputs_unchanged/1` stores the refreshed snapshot.
   Reason: a reset with no state-update path reports the same event at every handoff, and the two failed-turn callers
   match only `:ok` today (build.ex, `receive_developer/4`, `settle_transport_failure/4`; round 4, Sol, Opus).
   Undo: return `:ok | {:error, _}` again and stop on any shared-file change, as at 3ab70dce.
7. After a `.git/info/exclude` event, a Candidate path whose ignored state differs between the current and the
   Build-start exclude is terminal (`git-policy`), guarded or not, at that handoff and every later one.
   Reason: `git add -A` honours info/exclude, so a hidden file would be verified in the worktree but left out of the
   Candidate id and the publication commit (lib/kogen/git.ex:153,238); the guard filter drops guarded paths
   (guarded_paths.ex:56) (round 4, Opus, Sol).
   Undo: drop the rule and keep the ignored-file manifest's ordinary stray reporting.
8. Only the root `.gitignore` is `git-policy`; nested `.gitignore` files (e.g. `.pytest_cache/.gitignore`) are
   ordinary stray paths, and the two terminal messages are today's.
   Reason: `.gitignore` is an ordinary path today (guarded_paths.ex:31-34, guarded_paths_test.exs:201-209) and tools
   write nested ones as cache markers (round 4, Opus).
   Undo: extend the git-policy match to `**/.gitignore`.
9. The rework prompt restores tracked files with `git show HEAD:<path> > <path> && chmod <mode> <path>`, `<mode>`
   being `644` or `755` from the HEAD tree mode (round 5 adds the chmod half).
   Reason: `git checkout`/`git restore` write the worktree index under control's `.git`, which the write boundary
   denies (write_boundary.ex:241-248,290) (round 4, Opus); the guard reports an executable-bit-only change
   (guarded_paths_test.exs:13-39), and `>` onto an existing file keeps its mode, so bytes alone do not undo it
   (round 5, Sol).
   Undo: name another restore command in the prompt and in stray-file-reworked.
10. `guard_violations` is a new top-level review-packet key (`[]` when none; `schema_version` stays 1).
    Reason: review_packet_test.exs:15-17,30 pins the exact top-level key set, so the test and reviewer.md are guarded
    and updated rather than nesting the field (round 4, Sol, Opus).
    Undo: remove the key from `@keys` and the test, and the reviewer.md paragraph.
11. The packet's `guard_violations` objects carry `cycle`, `path_count`, a prefix of whole paths within a new
    per-profile `guard_paths` cap (4_096, 2_048, 512, 0), and the full list's `sha256`, `byte_count` and record
    `locator`; a shorter prefix sets `"truncated": true` and adds the existing `omission/4` item. The record keeps the
    complete list.
    Reason: `ReviewPacket` never exceeds 65,536 bytes and caps only notes, receipts, handoff and findings
    (review_packet.ex:20-36,174-207), so an uncapped list could fail the build; a byte cap over whole paths reuses the
    profile ladder and stub/locator/omitted conventions, and at most `@guard_reworks` entries reach Review, so the last
    profile's fixed-size objects always fit (round 5, Astra, Sol).
    Undo: drop `guard_paths` from `@profiles` and inline the full list (unbounded).
12. A failed Developer turn keeps today's order in `settle_transport_failure/4`: guard check first, then provider
    retry. Any violation left by a failed turn, including a rework turn with a retryable capacity marker, stops as
    `integrity`; a retry happens only on a clean guard and resends `ctx.developer_prompt` (the rework prompt). The
    stray-file-reworked provider fixture now cleans up before it fails; the fail-without-cleanup variant is (f2).
    Reason: build.ex `settle_transport_failure/4` retries only on `{:ok, marker}` and its comment says a guarded-path
    violation takes precedence; keeping it keeps "a failed turn with a violation never resumes" and needs no new
    precedence rule. Sol and Opus both found the round-4 fixture unsatisfiable; Opus proposed retrying on
    reworkable-only violations instead, which widens what a failed turn may leave behind (round 5).
    Undo: in `settle_transport_failure/4`, retry a retryable marker when the guard result is `{:rework, _}` and stop
    only on `{:stop, _, _}`; restore the round-4 fixture.
13. Notes of each turn that ended in a guard rework are kept in the controller context and prepended, under a
    controller header line per part, to the notes of the next turn that passes the guard; that combined text is the
    verified turn's `notes` for Jev (one reading), `developer_notes`, the packet and `cannot_comply`. Each
    `guard_violations` entry also stores its own turn's notes.
    Reason: `verify_turn/5` records notes and asks Jev only after the guard passes, and Jev reads only the current
    turn's message (build.ex `verify_turn/5`, `read_notes/3`), so a cleanup turn's "Deleted stray.txt" would replace a
    work turn's contract objection (round 5, Opus). Combining the text reuses every existing notes path unchanged.
    Undo: record only the current turn's notes and drop the kept-notes context key.
14. A `protected-path` stop keeps today's message "Candidate changed paths outside Approved guards: <paths>".
    Reason: candidate_verification_test.exs:161-168 asserts that prefix for an unguarded `.codex/hooks/**` tamper and
    is not guarded (round 5, Opus).
    Undo: guard candidate_verification_test.exs and update its assertion with the new message.
15. README.md's retry-budget paragraph (README.md:458-462) states the guard-rework limit and the new stop categories.
    Reason: README.md is guarded and that paragraph already documents `offline_retries` (round 5, Opus).
    Undo: drop README.md from `may_change_guarded_paths` and the Outcome line.

## Audit

- Round 1 (Astra, Sol, Opus): not ready — read-only copy breaks mode comparison/deletion/tests; budget sharing needs
  verification.ex; protected set incomplete; categories by prefix; existing tests outside guards. All adopted above.
- Round 2 (Astra, Sol, Opus): not ready — tagged errors vs guarded_paths_test; Approved-copy additions are rejected by
  approved_unchanged before the guard (now classified first, topmost entry listed); config.toml case; `.claude/**` too broad
  (now only loaded config); approved_mutation_test untouched; ledger refresh; terminal-wins precedence; offline_retries set
  in the fixture config. All adopted.
- Round 3 at 82ac4351 (all not ready): stale citations → function names; path listing collapsed in the prompt; .gitmodules,
  deletion and outside-turn cases; env-event shape and reset; 3 tests flip; ledger binds by name (script gone); title ≤50;
  review packet carries guard_violations; developer.md read-only line. All adopted.
- Round 4 at 3ab70dce (all not ready; evidence/reviews/round-4/): dedicated `@guard_reworks 2` instead of
  `offline_retries`, with proof that `offline_retries`/`offline_failures` are untouched and no fixture default change
  (Astra); `guard_violations` as a top-level packet key with review_packet_test.exs and reviewer.md guarded (Sol, Opus);
  exclude hiding terminal for guarded and unguarded paths, with new-file and guarded-file cases (Sol, Opus); refreshed
  snapshot threaded through all three callers, a failed-turn event case and a rework-turn no-repeat proof (Sol, Opus);
  one case per protected `.claude` subtree plus terminal-wins (Astra); root-only `.gitignore` and today's messages
  (Opus); tracked-file restore via `git show` (Opus); `approved_unchanged` before a failed-cycle resume (Opus);
  `developer_prompt`/`provider_retried` on a rework resume (Opus); baseline 3ab70dce, plain line cites,
  core_integrity_test.exs:196-209, the tracker-refresh-unstated disposition (Opus). All adopted.
- Round 5 at 3ab70dce (all not ready; evidence/reviews/round-5/; round-4 blockers confirmed fixed by Opus): bounded
  packet `guard_violations` with a per-profile `guard_paths` cap, digest-bound locator and omission item, proved on two
  5,000-path entries (Astra, Sol; Assumed 11); guard-before-retry kept for failed turns, the provider fixture now cleans
  up before failing and the fail-without-cleanup case added as (f2) (Sol, Opus; Assumed 12 — Opus's reworkable-only
  retry not taken); work-turn notes kept and combined for Jev, record and packet, with work-turn-notes-survive-rework
  (Opus; Assumed 13). Advisories adopted: exact chmod restore plus a mode-only case (Sol; Assumed 9); stale
  shaping-quality citation and lesson 22 in references.yaml (Sol); `protected-path` keeps today's prefix (Opus; Assumed
  14); (c2) "adds" `.codex/config.toml` (Opus, workspace_fixture.ex:121-131 creates no such file); README.md change
  named (Opus; Assumed 15); disposition to name the emitted finding id (Opus); Claude exclude-lock residual in
  risks.yaml (Opus).

## Dispositions

- `tracker-refresh-unstated` / `ledger-row-update-unstated`: not a defect. Approved shaping-quality replaces the first
  rule with the second (.kogen/intents/approved/shaping-quality/scenarios.yaml:361-370), which fires only when a Draft
  adds or deletes catalogued rows and guards or affects one ledger file without guarding both; this Draft guards both
  `priv/kogen/test-reliability.yaml` and `priv/kogen/test-reliability-remediation.yaml` (intent.yaml). If the landed
  audit still emits a finding, this disposition is rewritten to the exact finding id it emits (`<rule>` plus subject),
  since a disposition clears a finding by id.
- Round 6 (Opus, final): READY; advisories applied (attempt-0 wording + guarded reviewer marker; worktree mode assertion; a reworkable result still runs every remaining input check, new scenario rework-still-runs-every-input-check).
