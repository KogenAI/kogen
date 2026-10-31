# Remove the no-output stop on native shell calls

Slug: k-silence-revert
Model: not applicable — the change removes one watch around a single running shell call; no state machine, transition or interacting rule is added or changed
Acceptance:
- .kogen/intents/k-silence-revert/acceptance.feature
- features/steps/k_silence_revert_steps.js

K-SILENCE-REVERT (change_type: fix; ruling kogen-main, 31 Oct 2026, h04 review): revert rule 1 of K-HUNG-CHECK (kogen d42f6cc) now as its own small change, and keep rule 2. K-SILENT-PROGRESS re-lands a correct hang check later; it is not part of this change.

Problem: since d42f6cc, a native builder or reviewer `shell` call that writes no new output for 10 minutes is stopped with its process group (`cli/build/hungshell.go`, `shellSilence = 10 * time.Minute`). Working commands are often silent for longer: Studio's `mix test` ran 696-1158 s on the shared Macs on 30-31 Oct, and Kogen's own `go test ./...` prints nothing until a package finishes (kogen/build 600 s and kogen/shape 509 s at the default GOMAXPROCS). Every Studio Build whose builder runs the suite can have it stopped mid-run.

Outcome: native builder and reviewer `shell` calls are no longer stopped for being silent, however long they write nothing. Behaviour for rule 1 goes back to exactly what it was before d42f6cc: every native Build `shell` call and every native independent Review `shell` call is answered by the vendored kogen-loop shell tool directly, with its own unchanged result bytes (`exit status: <n>\n` plus the combined output, its capture and the 16384-byte cut). No `command_no_progress` event with rule `no_output` is ever written, no `no output for ...; Kogen stopped the command and its process group: ...` result or progress line is produced, and no `kogen-shell-*` temporary output file is used.

What is removed (all introduced by d42f6cc for rule 1):
- `cli/build/hungshell.go` is deleted (`watchedShell`, `shellSilence`, `shellAbandon`, `shellCapHalf`, `cappedFile`).
- In `cli/build/executor_native.go`, the `HandleCall` hook no longer intercepts `tools.ShellTool`; it is back to handling only `agent.ReportBlockerTool` (shell calls return `loop.Handled{}` so the vendored tool answers them).
- In `cli/build/review.go`, the reviewer's `default:` dispatch is back to `out, err := tl.Call(call)` with no watched-shell path.
- `cli/build/hungshell_test.go` is deleted with its tests `TestHungShellStoppedBuildLands`, `TestProgressingShellNotStopped`, `TestShellResultBytesUnchanged`, `TestReviewHungShellStopped` and its helpers (`shortenShellSilence`, `hungCommand`, `requireGone`, `stoppedText`, `eventIndex`); move any helper a new test needs into the new test file.
- `spec/prose/04-building.md` LOOP-5 returns to its exact pre-d42f6cc wording (the sentences about the 10-minute no-output stop are removed); the exact expected line is in the acceptance feature.
- `docs/configuration.md`, section `## Removed shell time limit`: the added sentence "One fixed stop is not a setting: a native shell call that writes no new output byte for 10 minutes is stopped ..." is removed, so the section is back to its exact pre-d42f6cc four lines (in the acceptance feature).

What stays exactly as landed (rule 2): a fixer, setup, acceptance, model check, configured check, stage check or Build baseline check command whose process group has had no live process for 60 seconds while its result has not reached Kogen still stops the Build with `environment/command_no_progress` and logs `command_no_progress` with rule `no_live_process`; a live command is never stopped by it. `cli/verify/hung.go`, `cli/verify/hung_test.go`, the `verify.RunWatched` routing in `cli/build/baseline.go`, `cli/verify/env.go`, `cli/verify/model.go`, `cli/verify/readiness.go`, `cli/verify/run.go` and the LOOP-11 wording in `spec/prose/04-building.md` are unchanged.

Boundaries: no new option, setting, environment variable, limit or timeout; no existing value is changed. External executors, Shape probes, the 120-second approval readiness bound, interrupts, the round deadline and round custody of process groups are unchanged. `spec/features/` is unchanged and `sh check.sh` in `spec/` must keep passing. The historical `.kogen/intents/k-hung-check/` package is not edited. Do not edit `cli/third_party/kogen-loop/**`, `cli/loop-pin.json` or `.kogen/project.yaml`. Tests use temporary directories only and stop only processes they started.

Test limitation (decided): the old bound was 10 minutes and the removal deletes the variable that let tests shorten it, so no test can run a silent call past the real old bound within the suite. The new regression tests run a silent call for 2 seconds (four times the 500 ms bound the removed tests used) through the real native Build and Review paths and require the vendored tool's ordinary result and no `command_no_progress` event. The acceptance scenario that the watch's code is gone distinguishes the fix from the current behaviour and from a plausible wrong fix that only raises the bound.

## Decisions
- Native builder and reviewer shell calls are never stopped for writing no output; behaviour is the pre-d42f6cc behaviour (source: request)
- LOOP-5 and the "Removed shell time limit" note return to their pre-d42f6cc wording (source: request)
- Rule 2 (no live process for 60 s with no result → environment/command_no_progress) stays exactly as landed, with its tests (source: request)
- Rule 1's tests are removed and replaced by inverted tests that a silent call is not stopped (source: request)
- No new option, limit or timeout (source: request)

## Source comparison
- Addressed: "remove the 10-minute no-output stop on native shell calls" → deletion of `cli/build/hungshell.go` and its two call sites (`cli/build/executor_native.go` HandleCall, `cli/build/review.go` default dispatch); acceptance scenario "The no-output shell watch is gone from Kogen's own code".
- Addressed: "back to the behaviour before d42f6cc for rule 1, including the docs and spec wording (LOOP-5, the 'Removed shell time limit' note)" → exact pre-d42f6cc LOOP-5 line and `docs/configuration.md` section body, checked verbatim in two scenarios.
- Addressed: "Rule 2 stays exactly as landed: ... 60 s with no result still stops the Build with environment/command_no_progress" → scenarios running `TestVerifyEndedCommandNoticed` and `TestVerifyLiveSilentCommandWaits` in `./verify`, and the unchanged LOOP-11 line checked verbatim.
- Addressed: "Rule 1's tests are removed or inverted (a silent call longer than the old bound is not stopped); rule 2's tests stay" → `cli/build/hungshell_test.go` deleted; new `TestSilentBuildShellNotStopped` and `TestSilentReviewShellNotStopped`. Literal 10-minute duration is not reproduced in tests (see Test limitation); the inversion uses a 2 s silent call plus the structural absence check.
- Addressed: "No new option, limit or timeout" → Boundaries paragraph.
- Preserved literals: `cli/build/hungshell.go`, `shellSilence = 10 * time.Minute`, `environment/command_no_progress`, 60 s, LOOP-5, "Removed shell time limit", d42f6cc, K-HUNG-CHECK, K-SILENT-PROGRESS, the Studio/`go test` timing evidence (prose only).
- Omitted: K-SILENT-PROGRESS (the later correct hang check) is explicitly out of scope per the ruling.

## Tests
- A silent native builder shell call is not stopped and returns the vendored tool's ordinary result: add `TestSilentBuildShellNotStopped` in `cli/build/silent_shell_test.go` — through `newEnv`/`e.build()`, the builder calls `shell` with `sleep 2; printf 'done\n'`, then writes `app.txt` and finishes; the Build lands one commit, the second builder request carries the tool output exactly `exit status: 0\ndone\n`, and the run's events contain no `command_no_progress` (regression)
- A silent native reviewer shell call is not stopped: add `TestSilentReviewShellNotStopped` in `cli/build/silent_shell_test.go` — `landScript` for the builder, then the reviewer calls `shell` with `sleep 2; printf 'done\n'` and submits `approve`; the Build lands one commit, the second review request carries exactly `exit status: 0\ndone\n`, and the run's events contain no `command_no_progress` (regression)
- The no-output stop and its tests are removed: delete `cli/build/hungshell.go` and `cli/build/hungshell_test.go` (`TestHungShellStoppedBuildLands`, `TestProgressingShellNotStopped`, `TestShellResultBytesUnchanged`, `TestReviewHungShellStopped`); acceptance scenario checks no Go file under `cli/` outside `cli/third_party` mentions `watchedShell`, `shellSilence`, `"no_output"` or `no output for`, and both files are absent (scenario)
- LOOP-5 and the configuration note return to their pre-d42f6cc wording: acceptance scenarios compare the exact LOOP-5 line and the exact `## Removed shell time limit` section body (scenario)
- Rule 2 still stops a command with no live process and no result, and waits for a live silent command: `TestVerifyEndedCommandNoticed` and `TestVerifyLiveSilentCommandWaits` in `cli/verify/hung_test.go` stay unchanged, and the LOOP-11 line stays verbatim (existing)

## Feasibility
- none
