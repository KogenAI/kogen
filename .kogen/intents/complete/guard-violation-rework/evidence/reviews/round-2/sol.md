## Findings

- **[BLOCKING]** `stray-file-reworked` cannot reach guard rework: the Approved-copy addition is rejected first by exact `approved_unchanged/1` comparison before `GuardedPaths.check/2`, while `__pycache__` is also filtered as volatile — `scenarios.yaml:7-14`; `lib/kogen/build.ex:1579-1586,219-227`; `lib/kogen/build/guarded_paths.ex:175-179` — use a nonvolatile added file and specify/implement an addition-only exception that still rejects modifications/deletions of frozen entries.

- **[BLOCKING]** Tagged GuardedPaths errors will break an existing test outside `may_change_guarded_paths`; it asserts the raw string for Git-policy drift — `intent.yaml:19-27`; `test/kogen/guarded_paths_test.exs:70-71` — add that test to the guarded paths and update it to assert the tagged result while preserving the user-facing message.

- **[BLOCKING]** The required protected set includes `.codex/config.toml`, but the terminal scenario exercises only `.codex/hooks/**`, `.codex/hooks.json`, and `.claude/**`; an implementation can therefore rework `config.toml` incorrectly while all listed checks pass — `INTENT.md:21-26`; `scenarios.yaml:40-57` — add a `.codex/config.toml` mutation case and evidence, or remove it from the protected-set requirement.

## Verdict: not ready