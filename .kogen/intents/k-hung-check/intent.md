# Stop waiting on commands that make no progress

Slug: k-hung-check
Model: not applicable — each rule is one watch over a single running command (its output size or its process group's liveness) with one outcome; the Build state machine gains only an ordinary stop reason
Acceptance:
- .kogen/intents/k-hung-check/acceptance.feature
- features/steps/k_namedfeedback_steps.js

Kogen must notice a command it is waiting on that can no longer make progress. Today it waits until an outer cap kills it, and nothing says which command hung. Two fixed rules replace that silent wait. Commands that keep making progress are never interrupted. No existing limit, timeout or retry value is raised. No option, setting, environment variable or CLI change is added.

**Rule 1: silent native shell calls.** This rule covers every `shell` call of the native builder (the kogen-loop round in `cli/build/executor_native.go`) and of the native independent reviewer (the reviewer's own call dispatch in `cli/build/review.go`). Progress means that the call's combined stdout and stderr grows. Kogen stops a call that has not ended and has written no new output byte for 10 minutes (`10m0s`, counted from the start or from the last new byte, checked at least once per second). Kogen ends the call's whole process group through the existing `sys.Session.RunContext` cancellation (SIGTERM, then SIGKILL after 5 s, joined). It then writes the run-log event, prints the progress line and returns this text as the call's result instead of an exit status:

```
no output for 10m0s; Kogen stopped the command and its process group: <command>
<the output the call produced before it was stopped>
```

The first line is followed by a newline and then the output bytes exactly as captured (nothing more when there were none). The usual 16384-byte tool-result cut applies. `<command>` is the call's `command` argument verbatim. The round continues: the model's next request carries that result. Nothing else stops and nothing is retried. If the ordinary result arrives before the stop takes effect, Kogen returns the ordinary result. After asking for the stop, Kogen waits at most 1m0s for the runner to return. If the runner has not returned by then, Kogen returns the same stopped result and continues without it; the abandoned wait is not joined.

Kogen records `{"event":"command_no_progress","owner":"build"|"review","name":"shell","command":<command>,"rule":"no_output","after_ms":<the silence bound in ms, 600000>}` in the run log, before that call's `tool_call` or `review_tool_call` event. It prints this progress line on stderr: `kogen: no output for 10m0s; Kogen stopped the command and its process group: <command>`.

Calls that are not stopped keep exactly the result bytes the vendored tool gives today:
- `exit status: <n>\n` followed by the combined output in write order;
- the runner's first and last 512 KiB capture with its `\n[... N bytes omitted ...]\n` marker;
- the 16384-byte cut;
- the error text for a non-string `command`;
- the foreign-kill refusal text, with nothing run.

The tool definitions, the builder and reviewer prompts and the request bytes are unchanged. Interrupts, the round deadline and round custody of process groups behave as before.

Mechanism (decided): Rule 1 lives only in Kogen's own code, through `loop.Hooks.HandleCall` for the builder and the reviewer's own dispatch for the reviewer. `cli/third_party/kogen-loop/**` and `cli/loop-pin.json` stay unchanged. Calls whose `command` is not a string, or that `sys.ForeignKill(command, session.Owned)` refuses, are left to the vendored tool unchanged. For any other call, Kogen:
- creates a private temporary directory outside the checkout (0700) holding an output file;
- runs `exec >>'<output file>' 2>&1 && exec /bin/sh -c '<command, single-quoted with '\'' escapes>'` with `RunContext` on the same session and repository root, forwarding the round's context, with no `RefuseForeignKill` because the refusal was already checked; the command therefore still runs as `/bin/sh -c <command>` in its own process group with stdin closed, inside the round's custody;
- watches the output file's size.

The result output is whatever the runner captured (normally empty), followed by the file's bytes, under the same 512 KiB capture rule. The directory is removed when the call returns, including when the wait is abandoned. With `KOGEN_LOG_LEVEL=debug` the debug line shows the wrapper text. Background processes a call starts now write to that file (unlinked once the call returns) instead of a pipe that is later closed. The call no longer waits the runner's 1-second output delay for them. Their later output was never part of a result.

**Rule 2: project commands that ended without a result.** This rule covers every command Kogen runs through verify's unbounded runner (`run` in `cli/verify/env.go` without an approval `Attempt`):
- fixers (`fix-<n>`);
- verification setup (`setup-<n>`);
- `acceptance`;
- the model check commands;
- configured checks;
- stage checks (`stage-<id>-<n>`);
- the Build's baseline checks in `cli/build/baseline.go`, which are routed through the same watch under their check name.

The command's process group is the group the session started for it, that is, the new entry in `Session.Groups()` after the start. While Kogen waits for the result, it checks at least once per second whether that group still has a member (`kill(-pgid, 0)` not returning ESRCH; unreaped zombies count as members). Kogen stops waiting when the group has had no member for 1m0s and the command's result still has not arrived. It logs `{"event":"command_no_progress","name":<step name>,"command":<command>,"rule":"no_live_process","after_ms":<the grace in ms, 60000>}` and returns `*sys.Error` with class `environment`, reason `command_no_progress`, exit 1 and detail `<name> had no live process for 1m0s but its result never reached Kogen; stopped waiting for: <command>`.

A Build stops through its ordinary stop path: the `failed` line, outcome `command_no_progress`, `result.json`, the checkpoint, and edits left in place. The stuck wait is abandoned, not joined. Rule 2 never stops a live command, however long it is silent. Configured commands may legitimately wait without output; for example, this host's `heavy.sh` waits silently for a host-wide lock. If no new group is observed (the start failed, or a group number was reused), the rule does not apply to that command. Results that arrive normally are unchanged.

Boundaries: external executors (Claude Code runs its own tool calls), Shape probes (their existing 5-minute bound), the 120-second per-step approval readiness bound and Git commands are unchanged. The values 10m0s and 1m0s are fixed constants. Go tests may shorten them only through package-level variables set inside the tests, never through a setting or environment variable. Do not edit `cli/third_party/kogen-loop/**`, `cli/loop-pin.json` or `.kogen/project.yaml`.

Documentation:
- In `spec/prose/04-building.md` LOOP-5, keep "no time limit and no setting adds one". Add that a native Build or Review `shell` call with no new output for 10 minutes is stopped with its process group, that the call's result names it, and that the round continues.
- In LOOP-11, add Rule 2: a project command whose process group has had no live process for 60 seconds while its result has not reached Kogen stops the Build with `environment/command_no_progress`; live commands are never stopped by it.
- In the `docs/configuration.md` "Removed shell time limit" note, add one sentence on the fixed no-output stop (not a setting).

`spec/features/` stays unchanged, and `sh check.sh` in `spec/` must pass.

Host safety: tests use temporary directories only, add no synthetic CPU load and stop only the process IDs and groups they started, never by name or pattern.

## Decisions
- A command that makes no progress is noticed and handled. The Build or round continues, or stops with a message naming the command, instead of waiting for an outer cap (source: request)
- Long commands that keep making progress are not interrupted (source: request)
- No limit, timeout or retry value is raised, and no new option or CLI change is added (source: request)
- Tests use fake commands with controlled behaviour; no test sleeps to synchronise with Kogen (source: request)

## Source comparison
- addressed: K-HUNG-CHECK, change_type fix, kogen-main 30 Oct 2026, from research cap8. The problem statement is not a prescribed fix. Rule 1 covers cap8 row 3: eu2 e2esl-eu2 r70-4-elixir, 45 cell-minutes, last function_call `HEX_OFFLINE=1 make build && npx cucumber-js --strict ...`, run log gap 22:24 -> 22:50 (26 minutes). A native builder call that stays silent is now stopped after 10 minutes, with a result and event naming the command, and the round continues. The `npx` versus pinned `$KOGEN_CUCUMBER` network note is diagnostic context only; no command is rewritten.
- addressed: Further evidence, 31 Oct 2026, kogen-delivery. In K-CHECKTIME-SHARD Build 7659baca (laptop kogen-linux-macbook, kogen 5d93641, run .kogen/local/runs/7659baca), the last event of verifying pass 3 was the acceptance command at 2026-10-30T22:44:15Z. At 01:42Z, pid 1549499 had no child processes, sat in futex_wait with 9 threads, held only its own pipes, at load 0.7, and stopped on TERM with "stopped in verifying: interrupted". Rule 2 notices a step whose process group has had no live process for 60 s and stops with `environment/command_no_progress`, naming the step and command. The root cause inside the runner is not known, so the rule is a watch, not a claimed root-cause fix.
- addressed: "the shell tool may live in kogen-loop; the Intent decides". This Intent decides Kogen-side handling through the engine's `HandleCall` hook. Protected kogen-loop and `loop-pin.json` stay unchanged.
- addressed: "Long but progressing commands are not interrupted; no limit/timeout/retry value raise; no new option or CLI change; fake commands, no sleeps as synchronisation". See Decisions, Boundaries and the Execution contract.
- superseded: K-DROP-SHELLTIMEOUT says "no per-call model-shell limit". That remains true for duration. The new fixed no-output stop is documented in LOOP-5 and in the configuration removal note.
- omitted: the private research files under /Users/almirsarajcic/Scratch.noindex/ are evidence only. Tests do not need them. Real `npx` and network hangs are represented by fake blocked commands. The runner anomaly behind Build 7659baca cannot be reproduced through the real runner, so its test withholds the result from the watch.
- omitted: silence-based stopping of verification commands, which would break legitimate silent waits such as `heavy.sh`; external executors; approval and Shape bounds (unchanged).

## Tests
- A native builder shell call that writes no output for the bound is stopped with its process group, its result names the command, the event and progress line are written, and the Build continues and lands: TestHungShellStoppedBuildLands in ./build (regression)
- A native shell call that keeps producing output for longer than the bound is not stopped and returns its ordinary result: TestProgressingShellNotStopped in ./build (integration)
- Ordinary shell results are byte-identical to the vendored tool's (exit status, combined order, syntax error, refusal without running, non-string command, cut): TestShellResultBytesUnchanged in ./build (integration)
- The native independent reviewer's silent shell call is stopped the same way, owner review, and the review reaches its verdict: TestReviewHungShellStopped in ./build (integration)
- A project command whose process group has ended while its result never arrives stops with environment/command_no_progress naming the step and command, and records the event: TestVerifyEndedCommandNoticed in ./verify (regression)
- A live but silent verification command outlasting the grace is waited for, and its real result is used: TestVerifyLiveSilentCommandWaits in ./verify (integration)
- Approval's 120-second steps, the existing Build, review, verify and kogen-loop tests, the spec prose (sh check.sh) and all configured checks still pass: existing suites and configured checks (existing)

## Execution contract

The named Go tests are implementation tests, not protected acceptance files. The protected Cucumber helper requires each exact test to run once and pass through `go test -json -count=1 <package> -run ^<name>$` from `cli/`. Use the existing test utilities: `newEnv`, the fake provider, `newConformanceAttempt`, the real reviewer setup of review_test.go, and the verify project helpers. Never call a real provider or the network.

Shorten the 10m0s and 1m0s bounds only through package-level variables set inside each test, and restore them; such tests cannot use `t.Parallel`. Every hang guard is the test's own failure bound (fail rather than hang, for example a 60 s select). It is never synchronisation. No test sleeps to wait for Kogen state. A fake command may pace or block its own behaviour.

1. TestHungShellStoppedBuildLands (cli/build, package build): run a full native Build (fake provider, `approveWithoutReview`) with the silence bound set to 500ms. In a temporary directory, create a FIFO `never.fifo` (syscall.Mkfifo) that is never opened for writing. Builder response 1 is one shell call with command C = `printf 'started\n'; echo $$ > '<tmp>/hung.pid'; read line < '<tmp>/never.fifo'`; response 2 is `finish`. Require:
   - Build exit 0 and exactly one new commit;
   - the next builder request carries, for that call, exactly `no output for 500ms; Kogen stopped the command and its process group: ` + C + `\nstarted\n`;
   - exactly one `command_no_progress` event with owner `build`, name `shell`, command C, rule `no_output`, after_ms 500, logged before that call's `tool_call` event;
   - stderr contains `kogen: no output for 500ms; Kogen stopped the command and its process group: ` + C;
   - the process ID in hung.pid no longer exists (kill(pid, 0) gives ESRCH) once Build returned.
2. TestProgressingShellNotStopped (package build): in a native builder round with the silence bound at 2s, call shell with P = `i=0; while [ $i -lt 15 ]; do echo line-$i; sleep 0.2; i=$((i+1)); done`. The fake command paces its own output. Require:
   - the result is exactly `exit status: 0\n` followed by `line-0\n` through `line-14\n`;
   - no `command_no_progress` event;
   - the measured call duration exceeded 2s, so the case is meaningful.
3. TestShellResultBytesUnchanged (package build): for each case, compare the output the native builder round actually delivers in its next request with the oracle `(&tools.Tools{Root: root, Session: s, Enabled: []string{"shell"}}).Run("shell", args)` followed by `.Cut()`, run in the same root with the same session. Cases:
   - (a) `printf 'out\n'; printf 'err\n' >&2; printf 'out2\n'; exit 3`;
   - (b) `if then`;
   - (c) `kill -0 1; touch '<tmp>/ran'`, which must be refused, with `ran` absent afterwards;
   - (d) `{"command": 5}`;
   - (e) `head -c 40000 /dev/zero | tr '\0' a`.

   Require exact equality in every case.
4. TestReviewHungShellStopped (package build): run a full Build with the real native independent reviewer and the silence bound at 500ms. The builder finishes. Reviewer response 1 is a shell call with the hung command of case 1, using its own FIFO and pid file; response 2 is `submit_review` approve with no findings. Require:
   - Build exit 0 and one commit;
   - the reviewer's next request carries exactly the stopped text for that command followed by `started\n`;
   - exactly one `command_no_progress` event with owner `review`, logged before the `review_tool_call` event of that call;
   - the pid is gone.
5. TestVerifyEndedCommandNoticed (cli/verify, package verify): set the grace to 50ms. Start a real fake command through a real `sys.Session` whose process group then ends, for example `printf done`. Give the watched wait a result source that never delivers. The real runner cannot produce the Build 7659baca anomaly; this is the only withheld part, and the group liveness observed is real. Use step name `acceptance`. Require:
   - the error is `*sys.Error` with class `environment`, reason `command_no_progress`, exit 1 and Detail exactly `acceptance had no live process for 50ms but its result never reached Kogen; stopped waiting for: ` + the command;
   - exactly one logged event with name `acceptance`, the command, rule `no_live_process` and after_ms 50.
6. TestVerifyLiveSilentCommandWaits (package verify): set the grace to 50ms. Run a real `verify.Verify` pass whose setup command is `sleep 1; printf 'late\n'; exit 4`; the command blocks silently and alive far longer than the grace. Require:
   - no error;
   - `Setup[0]` has status 4 and output `late\n`;
   - `Failing` is `["setup-1"]`;
   - no `command_no_progress` event.

## Feasibility
- Repository inspection: `loop.Hooks.HandleCall` lets Kogen answer a call without forking the engine. Engine round custody already ends the groups started through the shared session. `sys.ForeignKill` and `sys.RefusalText` are exported. Kogen must apply `Output.Cut` itself to handled results. The reviewer dispatches its calls itself. Build verification calls `Session.Run` without a timeout or context. During a run, Kogen itself holds both ends of the supervisor lifeline pipe, which fits the 7659baca observation of a process holding only its own pipes inside the runner's wait. No protected edit is required.
- Local shell check in a temporary directory, run in this session (not a Kogen probe record): macOS `/bin/sh` (bash 3.2) reported a syntax error after a one-line `exec >>file 2>&1` prefix on the original stderr, not in the file. With the decided `exec >>file 2>&1 && exec /bin/sh -c '<command>'` form, bash and `/bin/dash` wrote the parse error into the file with exit status 2, the same text as a direct run. `$0` stayed `/bin/sh`, and `exit 7` passed through. This qualifies the wrapper, not the feature.
- No external protocol, provider or library assumption needs documentation lookup. No generated protected fixture or observer is proposed, so no evidence obligation is declared.
