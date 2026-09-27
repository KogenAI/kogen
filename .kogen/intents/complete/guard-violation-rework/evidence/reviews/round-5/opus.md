## Findings

The Round 4 blockers are fixed:
- guard reworks now have their own budget (`@guard_reworks 2`);
- `review_packet_test.exs` and `reviewer.md` are in the guarded paths;
- hiding a path through a changed exclude now stops the Build, for guarded paths too;
- the refreshed snapshot is passed through all three callers;
- each protected `.claude` subtree has its own case.

I read the code at the checkout, 3ab70dce. These citations hold there: `build_workspace_test.exs:607-639,672-673,760-773`, `core_integrity_test.exs:196-209`, `guarded_paths_test.exs:41-79,201-209,211-219`, `isolation_test.exs:169-175`, `git.ex:153,238` and `write_boundary.ex:241-248,290`. Nothing conflicts with D1 or rules 36, 37 or 44.

- **[BLOCKING] The third fixture in `stray-file-reworked` contradicts the Draft's own failed-turn rule.**
  - On the rework resume, the fake prints the capacity marker and exits non-zero *before* it removes anything, so `stray.txt` is still there (`scenarios.yaml:13-15`).
  - INTENT.md:65-66 says a failed turn with a violation stops as `integrity` with zero resumes. Today's code agrees: the guard result is checked before any provider retry (`build.ex:1218-1247`).
  - The scenario instead expects a provider retry and an accepted Build (`scenarios.yaml:25-26`). An implementation can't satisfy both.
  - A real Codex capacity failure in the middle of a rework will usually leave the stray paths behind.
  - **Fix:** add a rule. A retryable provider failure whose only violations are reworkable retries once with the rework prompt. Terminal violations still stop. Keep the fixture as written.

- **[BLOCKING] The work turn's notes are lost when a guard rework follows it.**
  - `verify_turn/5` records `developer_notes` only after the guard passes (`build.ex:771-779`), and Jev reads only the current turn's message (`build.ex:779,1015-1022`).
  - After a rework, Jev, the attempt record and the packet's `developer_notes` (`review_packet.ex:180`) see only the cleanup turn's notes.
  - A real headless session will end that turn with something like "Deleted mix_lock_user501". Any contract objection from the real work turn is never read, and the Build can be accepted over it.
  - The fakes hide this because `scenario_response.py` gives the same canned answer every turn.
  - **Fix:** save the work turn's notes in its `guard_violations` entry. Have Jev read them, or the concatenation of both turns, and have the packet carry them. Add a case: the fake objects in turn 1, a rework follows, and the Build still stops as `cannot-comply`.

- **[ADVISORY]** `candidate_verification_test.exs:161-168` isn't guarded, but it asserts `=~ "Candidate changed paths outside Approved guards"` for an unguarded `.codex/hooks/**` tamper. That tamper will now stop as `protected-path`, and the Draft says only that the message names the path. **Fix:** require the `protected-path` message to keep that prefix.

- **[ADVISORY]** Case (c2) says "edits `.codex/config.toml`", but the fixture never creates that file (`workspace_fixture.ex:121-131`). **Fix:** say "adds".

- **[ADVISORY]** `README.md` is guarded, but no Outcome line says what should change in it. The retry-budget section at `README.md:458-462` is the natural place. **Fix:** name the change (guard reworks and the new stop categories), or drop `README.md` from the guarded paths.

- **[ADVISORY]** The `tracker-refresh-unstated` disposition in questions.md:68 uses the bare rule name. shaping-quality's finding ids are `<rule>` plus a subject, and a disposition clears a finding by id (`approved/shaping-quality/scenarios.yaml:334,388-389`). **Fix:** once shaping-quality lands, change the disposition to the exact finding id the audit emits.

- **[ADVISORY]** Claude Code's exclude block from lesson 19 (`**/.claude/scheduled_tasks.lock`) combined with case (h) causes a problem. If a Claude Developer leaves that lock file and the exclude block lands during the Build, the file's ignored state changes and the Build stops as terminal `git-policy` instead of being reworked. **Fix:** note this as an accepted residual in `risks.yaml`, since the Draft rules out changing the volatile list.

## Verdict: not ready

The claude.ai Stripe connector needs authorizing in your claude.ai connector settings before it can be used; this review didn't need it.
