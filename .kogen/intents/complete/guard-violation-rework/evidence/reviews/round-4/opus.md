## Findings

I read the code at the current checkout, 3ab70dce, not at 82ac4351. The Round 3 blockers are fixed: the citations now name functions, the prompt collapses directories, and there are `.gitmodules`, deletion and outside-turn cases, the env-event shape, the ledger-by-name rule, the title and packet visibility. The line citations still hold (`build_workspace_test.exs:607-639,672,760-773`, `guarded_paths_test.exs:78,211-219`, `isolation_test.exs:169-175`). Nothing violates D1, rule 36, rule 37 or rule 44.

- **[BLOCKING] Adding `guard_violations` to the review packet breaks a test the Developer isn't allowed to change.** `test/kogen/review_packet_test.exs:15-17,30` asserts the packet has exactly the keys in `@keys` (`review_packet.ex:24-26`), and that test isn't in `may_change_guarded_paths`. So `reviewer-sees-guard-violations` can only pass if that test fails. — **Fix:** guard `test/kogen/review_packet_test.exs`, and `priv/kogen/prompts/reviewer.md` so the Reviewer is told what the new field means.

- **[BLOCKING] The claim "the ignored-file manifest still reports any file a new exclude rule would hide" is false for guarded paths.**
  - Newly ignored paths are added to `paths` and then dropped if they're guarded (`guarded_paths.ex:96-101,56`).
  - The Candidate id and the publication commit both use `git add -A`, which honours `info/exclude` (`git.ex:153,238`).
  - So if an outside tool adds an exclude rule matching a new guarded file, the Build now continues. Verification runs on the worktree, which has the file, but the published commit doesn't. Today `same_config` stops the Build before this can happen.
  - **Fix:** after an exclude environment event, report any path whose ignored state changed since capture, whether or not it's guarded (terminal). Add a guarded-file case to `shared-git-files-do-not-stop`.

- **[ADVISORY] The environment-event return has three callers, and the Draft only covers one.** `post_developer_inputs_unchanged` is also matched on `:ok` in `receive_developer/4` (`build.ex:749-757`) and `settle_transport_failure` (`build.ex:1218-1247`). There, `{:ok, events}` would raise a CaseClauseError. — **Fix:** name all three callers and add a case with a failed turn plus an environment event.

- **[ADVISORY] The "no repeat on the next turn" check is never exercised.** `fake_codex_simple_accept` runs only one Developer turn. — **Fix:** also write `stray.txt` in that fixture so a rework turn follows, then assert exactly one event per file.

- **[ADVISORY] The `.gitignore` message is contradictory.** INTENT.md:42-43 says `.gitignore` keeps "the config message". In fact `.gitignore` is an ordinary stray path (`guarded_paths.ex:31-34`, `guarded_paths_test.exs:201-209`). — **Fix:** keep today's messages: stray-path for `.gitignore`, config for `.gitmodules`, both with category `git-policy`. Limit it to the root `.gitignore`, so cache files like `.pytest_cache/.gitignore` stay reworkable.

- **[ADVISORY] Restoring a tracked file is never proven.** The fake only runs `rm -rf` on untracked paths. A real Developer can't use `git checkout`/`git restore`, because the worktree index is under control's `.git` and the write boundary denies it (`write_boundary.ex:241-248,290`). — **Fix:** have the prompt name `git show HEAD:<path> > <path>`, and add a case where a tracked, unguarded file is modified.

- **[ADVISORY] An Approved-copy addition made by a failing check gets blamed on the Developer.** `resume_after_failed_cycle` (`build.ex:873-889`) never calls `approved_unchanged`, so the next handoff classifies the addition as reworkable. The result is `guard-violation` instead of `integrity`. — **Fix:** check `approved_unchanged` after each cycle, before resuming.

- **[ADVISORY] A provider retry during a rework resume would resend the wrong prompt.** `retry_developer` reuses `ctx[:developer_prompt]` (`build.ex:1260`). — **Fix:** set `developer_prompt` and `provider_retried: false` on a rework resume, the same way `build.ex:883` does.

- **[ADVISORY] Tidy-ups before the re-preflight:**
  - The package disagrees on its baseline: `intent.yaml:8` says 3ab70dce, but INTENT.md:3 and scenarios.yaml:1 say 82ac4351.
  - The `~:` line cites should be plain numbers. `core_integrity_test.exs` should cite 196-209.
  - shaping-quality's `tracker-refresh-unstated` rule still names the deleted refresh script (`approved/shaping-quality/scenarios.yaml:352-353`). Add a `## Dispositions` entry to questions.md so it doesn't block.
  - Make `offline_retries: 2` a per-test option; don't change the fixture default of 4 (`workspace_fixture.ex:33`).

## Verdict: not ready

The claude.ai Stripe connector needs authorizing in your claude.ai connector settings; this review didn't need it.
