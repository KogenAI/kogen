**Verdict: not ready**

I checked every file in the package, including `evidence/`, against `dece3e84`, reading only. The Stop-hook unit tests (H1–H28) are sound. The problems are in the evaluation port and the two paid targets.

## Blocking findings

1. **The port plan leaves out code that the live cases and the Draft's own tests need** (`INTENT.md:133-146`, `CANDIDATE.md:56-58`). Starting from HEAD and porting only the listed functions leaves these gaps:
   - **Helper sessions.** Codex 0.156.1 helper rollouts replay the parent's `session_meta` and turns; qb's and Zuj's comments say so, and qb added a test for it. HEAD's `rollout_summary` (`driver.py:254-267`) therefore picks up the parent's id and models, and `integrity.py:158` rejects any rollout with more than one `session_meta`. `observed_role` and `integrity.py:165` also don't map Kogen's `scout` agent. The new prompts make every case start helpers, so `all_profiles_match` and integrity would fail in every case and in the smoke. qb's fixes are not in the list: `rollout_summary(…, inherited_turns)`, `rollout_turn_ids`, `parent_thread_id`, the scout mapping, the `all_owned_terminal` change and integrity's `validate_native` filter.
   - **Panel answers in integrity.** `integrity.py:79-82` rejects any sent entry without text. That includes the native-panel entries V4 appends, and qb's `ordered_turn_bindings` change that skips them is not listed.
   - **V7.** The test `test_a_helper_still_running_near_the_deadline_stops_with_the_session` (`scenarios.yaml:580-581`) needs `running_helpers`, `helper_terminal` and `HELPER_STOP_MARGIN_SECONDS`, none of which are listed.
   - **Resume arguments.** qb's `resume_transport.exp` reads argv 8-11 (intent id, route, launch id, toolchain path). The helpers that supply them (`read_intent_id`, `generate_uuid7`, `shaping_toolchain_path`) and the `resume_exact` change are not listed. An empty intent id makes every resumed stop "no package", so it is never audited. An empty route falls back to `default_route: claude`, which is a Claude auditor. That breaks the "no Claude" claim.
2. **"Take qb's `shaping_evaluation_test.exs`, then fix three things" is wrong** (`INTENT.md:97-98`, `CANDIDATE.md:31`). Taking it would:
   - delete the tests at `:127`, `:131` and `:137`. The `:137` test is the only one that runs `driver_turn_end_replay_test.py`, which V3 requires (`scenarios.yaml:556-558`);
   - drop HEAD's heavy-rehearsal split. qb's `@moduletag timeout: 300_000` is the "300 s hang" from P2;
   - add a test that asserts the literal `spawn mix kogen.shape --route codex`, which contradicts keeping `--route $route` (`shape_transport.exp:67`);
   - add tests that call `copy_project_into_fixture`, `rollout_turn_ids` and `rollout_summary(…, inherited)`, which are not in the port plan.
3. **Both live runs would talk to the fake Jev.** `isolated_case.ex:378-385,440` puts the offline `KOGEN_JEV_TRANSPORT` and `KOGEN_JEV_SECURITY` fakes into every isolated child, and both live owners inherit them.
   - The Draft only clears `KOGEN_ROLE` and `KOGEN_HARNESS_HOME` (`INTENT.md:191-194`, `CANDIDATE.md:29-30`). qb's `real_jev_env()` is never mentioned.
   - Without it, the rule "at least one case shows validated real Jev answers" (`scenarios.yaml:657-658`) fails.
   - The claim that the hook audits with real Jev (`INTENT.md:24-27`) is false for the smoke run.
4. **The gate command contradicts itself.** `scenarios.yaml:645-650` specifies `mix run --no-start -e '…gate_questions_main()'`. That is exactly the cold-compile fallback that risk `live-gate-and-codepaths` forbids (`risks.yaml:92-97`). The command should be a bare `elixir -pa <paths> -e …` run from the project root, like `driver.py:735-741` and qb's `question_gate_command`.
5. **The smoke owner's assertions don't allow for native panels.**
   - The new `shaping.md` tells Codex to ask through `request_user_input`. V4 counts each panel answer as a reply.
   - `live_shaping_smoke_test.exs:125,128` and `integrity.py:223` require exactly one reply and one terminal binding.
   - Nothing requires `SMOKE_REQUEST` (`scenarios.yaml:750-753`) to forbid the question tool. HEAD adds `TRANSPORT_COMPLETION_SUFFIX` only to resumed messages (`driver.py:186-195`).
   - The smoke's helpers also stay on slow profiles (K1 pins them unchanged) while the prompts make it start helpers, so fitting in 300 s is unproven.
6. **The generic-answer rule breaks a wrong control the catalog pins.**
   - With qb hunks 1-4 taken, the `missing_answer` fake still has an open `## Ask the Shaper` entry and no `scenarios.yaml`.
   - The rule "every other asking stop gets GENERIC_ANSWER" (`scenarios.yaml:468-474`) then appends an answer instead of firing TurnEndFailFast.
   - So `test_smoke_wrong_control_missing_scripted_answer_fires_fail_fast` (`driver_smoke_rehearsal_test.py:286-292`) fails.
   - `scenarios.yaml:756-757` says the smoke appends no generic answer but gives no mechanism. This is why qb changed hunk 5.
7. **The environment rule is not met by the Draft's own "unchanged" files.**
   - `INTENT.md:358-370` says every test must clear or set `KOGEN_ROLE` and `KOGEN_HARNESS_HOME`.
   - `shaping_smoke_rehearsal_test.exs:15` and `prepare_test.exs:150,163,196,238` stay unchanged and inherit both.
   - The `child_environment()` call sites omit `driver.py:938` (the resume Popen, which V12's "drive() Popen" covers) and `:1489`/`:1506`.
8. **`fast_auditor.ex` has no caller in this slice** (`INTENT.md:101-102`, `scenarios.yaml:721`). Only slice 4's live-shape-to-build test calls `FastAuditor.patch!`. `mix.exs` has no `elixirc_paths`, so the file isn't even compiled. It is slice-4 plumbing without a caller (direction 9).
9. **How a TUI Stop-hook block shows up in the rollout was never probed.** HEAD's `ordered_turn_bindings` rejects "distinct native turn intervenes" and "native user intervenes" (`integrity.py:104-105`), and `drive` treats the first `task_complete` as the end of a turn. `INTENT.md:394-396` says no probe was possible before Build, but one was: a stub `-c hooks.Stop` that blocks once, in a throwaway TUI session. That is the smallest probe, and the Draft's own rules require it.

## Notes

- **Citations** all match HEAD: the `driver.py` lines, `codex.ex:56/143/216/254/257-260/265-267`, `harness.ex:359-365`, `environment.ex:188-189/426/463-473`, the `jev_layer.ex` helpers, `intent.ex:410`, and `README.md:990-992/1018-1019/1030-1031`.
- **Landed audit interface:** the hook uses `audit/2`, a `DateTime` `:clock`, `Report.write/runtime_dir/latest_revision`, and the exit and usage rules correctly. qb's `stop_hook.ex` needs more than the six listed adaptations. It must also change:
  - `chain_ms` at an allowed stop (H16 expects 2 400 000; qb gives 0);
  - the block-limit text;
  - the summary format (`min`, `\n` joins, the `none` lines);
  - the `{:error, reason}` text;
  - `launch_ms` taken from the clock.

  The tests pin all of these, but CANDIDATE.md should list them. Separately, "the chain resets at every allowed stop" conflicts with H4, where `chain_blocks` stays 1 after a stalled stop.
- **Test values checked:** H3's 16 173 bytes (99 + 423×38) is right. H7's summary text matches probe P3. K1's diff matches `config.yaml:15,18`. H7 and H16 need the private `flow_checkout!` from `shaping_audit_flow_test.exs:56` copied into the hook test.
- **Ledger:**
  - Editing only row t001's `declaration` is consistent: the catalog binds rows by test name, and `validate_remediation` ignores `declaration`.
  - That row's `public_outcome` still says "five…". The catalog test only requires it to be unique, so it passes but is out of date.
  - The renamed task test isn't catalogued.
- **Scope:** every scenario's `affected_paths` is inside `may_change_guarded_paths`.
- **Claude:** `driver.py`, `--prepare` and Jev need no Claude. That only holds once findings 1 (the resume route) and 3 are fixed.
- **Connectors:** the claude.ai Stripe connector needs authorizing in your claude.ai connector settings before it can be used. It wasn't needed for this review.
