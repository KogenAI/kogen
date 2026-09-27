## Findings

- **[BLOCKING] Existing tests still expect a shared git-file change to stop the Build, and the draft doesn't list them.**
  - `test/kogen/guarded_paths_test.exs:41-79` and `:211-219` assert that a `.git/config` change returns "Git configuration or ignore policy changed…".
  - `test/kogen/build_workspace_test.exs:760-773` asserts that the Build stops.
  - Under `shared-git-files-do-not-stop`, all three must flip. `existing-expectations-updated` (`scenarios.yaml:62-72`) instead says "byte-identical messages" and "no assertion is dropped".
  - **Fix:** name these three tests as rewritten to the environment-event rule, and state that only a `.gitmodules` change keeps today's config message.

- **[BLOCKING] The ledger step names a script that no longer exists.** `INTENT.md:40-41` says to run `refresh_test_reliability_sources.py`, but build-reliability deleted it and removed `source_sha256` (`complete/build-reliability/scenarios.yaml:1204-1207`, `test/kogen/test_reliability_catalog_test.exs:19`).
  - Rows now bind tests by name. Only two touch these files: "preserves core integrity for each scenario" and "rejects an unguarded executable-bit change when core.filemode is false".
  - **Fix:** say "edit a row in both ledger files by hand only if its bound test is renamed".
  - Separately, shaping-quality's `tracker-refresh-unstated` rule (`approved/shaping-quality/scenarios.yaml:352-353`) still names the deleted script.

- **[BLOCKING] Most citations are stale at 82ac4351, and `shaped_against` is still 6dad9430 (`intent.yaml:8`).**

  | Location | Draft cites | At 82ac4351 |
  |---|---|---|
  | `post_developer_inputs_unchanged` | `build.ex:1179-1183` | `build.ex:1277-1281` |
  | `approved_unchanged` | `build.ex:181-228` / `219-227` | `build.ex:222-231` / `223-227` |
  | `resume_developer` | `build.ex:701-709` | `build.ex:685-694` |
  | failed turn / `verify_turn` | `build.ex:762-786` | `build.ex:747-758` / `769-797` |
  | `@stop_categories` / `stop_category` | `build.ex:1661-1682` | `build.ex:2042-2064` (`stop/3` at `2009`) |
  | `--setting-sources` | `claude.ex:162-163` | `claude.ex:213-214` |

  - Shaping-quality's `stale-anchor` check blocks on this.
  - Shaping-quality also changes `build.ex` (its `intent.yaml:313`). **Fix:** cite by function name, or re-derive the lines after it lands.

- **[BLOCKING] The title is 57 characters.** Shaping-quality's `title-format` limit is 50, and that check can't be disputed (`approved/shaping-quality/scenarios.yaml:366-368,390-393`). **Fix:** e.g. "Rework stray paths instead of stopping" (`intent.yaml:3`).

- **[BLOCKING] The scenario and INTENT disagree on which paths the prompt lists.**
  - `stray-file-reworked` expects the prompt to list `mix_lock_user501`.
  - `GuardedPaths` lists files, because `git ls-files --others` runs without `--directory` (`guarded_paths.ex:92`). So it reports `mix_lock_user501/lock_0`.
  - INTENT reduces to the topmost path only for Approved-copy additions (`INTENT.md:15-16`).
  - **Fix:** either expect `lock_0` in the scenario, or state that the prompt (not the stop message) collapses untracked directories to their topmost new directory.

- **[ADVISORY] The Reviewer never sees reworks.**
  - A real Developer that edited a needed file outside the guards is now told to revert it.
  - `guard_violations` goes only into the attempt record, not the review packet. Before, this stopped the Build loudly and the Draft went back to Shaping (rules 43/44).
  - **Fix:** put `guard_violations` into the review packet, or keep changes to tracked files terminal.

- **[ADVISORY] A real Developer may refuse the rework, while the fake always obeys.**
  - `priv/kogen/prompts/developer.md:46` says the Approved package is read-only, yet the rework prompt asks the Developer to delete inside it. **Fix:** have the rework prompt say that deleting the listed added entries restores the frozen package.
  - Lesson 21 was caught at publication (`build-failure-lessons…:115-118`), which this draft still stops as `integrity`. Say so in Why, because the fix does not cover that case.

- **[ADVISORY] `questions.md:8-9` still lists `.claude/**` as terminal**, which contradicts the narrowed set in INTENT. Case (d) uses `.claude/settings.local.json`, which `--setting-sources project` does not load. Use `.claude/settings.json` instead.

- **[ADVISORY] The environment event may repeat on every later turn.** The snapshot is frozen at capture (`guarded_paths.ex:53-54`), so the same change is seen again each turn. **Fix:** state whether the snapshot is reset after the event is recorded.

- **Checked and fine:**
  - The prior round-2 blockers are resolved: tagged-error test guarded, Approved-copy additions classified before the guard, `config.toml` case added, `.claude/**` narrowed, `approved_mutation_test` untouched, terminal wins.
  - `offline_retries` is required and set in `workspace_fixture.ex:33`, and that file is guarded.
  - `candidate_verification_test.exs:161-173` passes unedited because the message is unchanged.
  - Nothing violates D1 or rules 36/37, and every new return has a caller.

## Verdict: not ready

The Stripe connector on claude.ai needs authorizing in your claude.ai connector settings; it wasn't needed for this review.
