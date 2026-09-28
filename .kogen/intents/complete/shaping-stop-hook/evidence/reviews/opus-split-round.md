**Verdict: not ready**

There are two blocking findings, and they share one cause. The Draft changes `pinned_smoke_config`, but the smoke rehearsal's own synthetic project in `driver_smoke_rehearsal_test.py` `setUp` can't pass under the new rules, and the Draft never says to change that `setUp`. Everything else is sound. H1–H28 and P2–P5 need only small wording fixes, listed in the notes.

## Blocking findings

1. **The two catalogued smoke controls, K3 and K4 all fail under the new `pinned_smoke_config`.**
   - The rehearsal's synthetic config (`driver_smoke_rehearsal_test.py:73-76`) has a `codex-fake` route with only `harness:` and `shaping:` lines. It has no `auditor:` line and no `worker:` or `expert:` helper lines.
   - The Draft now makes `pinned_smoke_config` refuse exactly that shape (`INTENT.md:296-301`, `scenarios.yaml:483-485`).
   - `driver.run_smoke()` calls `smoke_files()` before anything else (`driver.py:1242`, `:610`). It raises "smoke: the codex route has no auditor entry to remove", so both catalogued controls fail. Those are `test_smoke_rehearsal_dispatches_real_functions_and_manifests_once` and `test_smoke_wrong_control_missing_scripted_answer_fires_fail_fast`, pinned at `verification_targets.yaml:81-82`.
   - `rehearsals.exs:76-86` then stops `check`.
   - The Draft says these controls pass "with their bodies and fakes unchanged" (`scenarios.yaml:488-492`, `:540-545`; risk `self-hosting`). It lists the fake's edits as a wrong result (`:503`) and never mentions `setUp`.
   - qb avoided this because its version did nothing when the auditor line was missing (qb diff `6727-6729`).
   - **Fix:** give the exact lines `setUp`'s `codex-fake` block gains: an `auditor:` line, a `helpers:` block with flow-map `scout`, `worker` and `expert` lines, and nothing else. Also state that this edit is allowed.

2. **K3 can't exit 0 as written** (`scenarios.yaml:534-538`).
   - The rehearsal project's `.gitignore` is only `.kogen/intents/drafts/` (`:80`), and `copy_fixture_source_tree` copies it into the fixture (`driver.py:411-412`).
   - K3's fake startup writes hook files under the fixture's `.kogen/runtime/shaping-audits/`. There they are untracked and not ignored.
   - `git status --porcelain` and `source_snapshot` then both differ from the baseline (`driver.py:623-629`, `:1074-1086`). `case_succeeded` fails (`:1463-1465`) and `run_smoke` returns 1.
   - "Ignored by `.gitignore`" (`scenarios.yaml:486`) is true of the real repository (`.gitignore:13`), not of this rehearsal.
   - **Fix:** say that K3 adds `.kogen/runtime/` to the rehearsal project's `.gitignore`, and say where: inside K3 itself, or in `setUp` together with finding 1.

## Notes

**Citations.** All match `dece3e84` except one:
- `flow_checkout!/0` is at `shaping_audit_flow_test.exs:56-64`, not `:55-63`. That range is cited in `INTENT.md:98`, `scenarios.yaml:7,45` and the note in `intent.yaml`.
- Checked and correct: `codex.ex`, `harness.ex`, `environment.ex`, `intent.ex:410/667`, `driver.py:583-595/609/1189`, `README.md:990-992/1018-1019/1030-1031`, `report_error/2` at `:151-169`, the renamed task test at `:242-254`, and `config.yaml:15,18,21,22`.

**`stop_hook.ex` changes.**
- The twelve changes are complete against qb's code, including `chain_ms` from the stored `chain_start`, the block-limit text, the summary format, `error_text/1`, `launch_ms` from the second clock read, and the UUIDv7 check. The chain table agrees with H4, H5 and H16.
- One gap: qb caches the `error` decision in `hook-state.json`, because `skip_key` comes from the environment. `stop_hook.sh` would then replay an error on an unchanged package. The Draft only says "a block is never cached". Say whether an error is cached.

**H, P and K results checked.**
- H3's 16 173 bytes is right.
- H7's minutes, and H17's `launch_ms` of 121 500, are right.
- H14: the bound is false on stop 1 and true on stops 2 and 3, with two records.
- H16's second stop blocks rather than hitting the auditor bound: the auditor is skipped because a deterministic finding is open.
- H13's symlink path is relative to the package (`package.ex:125`).
- `audit_env!/1` sets `FAKE_AUDITOR_MESSAGE=empty` (`fixture.ex:165`), so H8, H12 and H26 do reach `ready`.
- H24 matches `check.sh:10-12`.
- P2's escaped command string matches `Jason.encode!`.
- K1's `-` and `+` lines, and their order across the three diff hunks, are right.
- Adding tests to catalogued files needs no ledger row: `TestReliabilityCatalog.validate` checks only the existing rows.

**Clearing `KOGEN_ROLE` and `KOGEN_HARNESS_HOME`.**
- `prepare_test.exs`: the four `System.cmd` sites (`:150`, `:163-166`, `:196-202`, `:238`) are all of its external commands, and "eight tests" is right.
- `shaping_smoke_rehearsal_test.exs`: `:15` is its only child process. K5 in the isolated child is sound.

**P1's test oracle.** Zuj's prompts don't contain several of the listed passages word for word:
- item 1: "read … The root stays idle";
- item 4: Zuj has "a product gap *that* a helper finds";
- item 5: "not even something that looks important";
- items 6 and 8 are paraphrases.

Say "insert these exact sentences", or list the exact substrings to assert. Otherwise the Developer and the Reviewer can disagree on what "states" means.

**H27.** "it does not run as a Shaper Stop hook" is split across `README.md:1018-1019`. Refuting it on the raw text passes even if the sentence stays. Compact whitespace first.

**Independence and scope.**
- Nothing depends on `shaping-evaluation-live` or slice 5. The `--prepare smoke` check in `rehearsals.exs` reads the real config, which has every line the new function needs.
- Every `affected_paths` entry is inside the 22 `may_change_guarded_paths` patterns.

I couldn't write a plan file or exit plan mode in this session: those tools weren't available. This review was read-only. Separately, the claude.ai Stripe connector needs authorizing in your claude.ai connector settings before it can be used; it wasn't needed here.
