# Re-pin vendored kogen-loop to 33e7f4ec

Slug: k5-loop-repin
Model: not applicable — a vendored-dependency update with a small wiring and diagnostics change; no state machine.
Acceptance:
- .kogen/intents/k5-loop-repin/acceptance.feature
- features/steps/k5_loop_repin_steps.js

Update the vendored kogen-loop from `bbf3fdd6d2e79b96eab6af23bcd6d66212893388` to `33e7f4ec8ba899fc4aa621127379e5cb26b77648` ("Repair Linux timeout observation" at ef0f215f plus "Expect Linux word boundaries in search test"). On Linux an `ESRCH` from the group probe used to be read as "group gone" too early; the new `sys.Session.Run` proves whole-process-group absence before reporting a timeout. Proof: `research/benchmarks/outputs/LOOP/ESRCH-CORRECTION-2026-10-27.md` in the Kogen knowledge folder.

Required work:
1. Replace `cli/third_party/kogen-loop` by running `sh packaging/sync-kogen-loop.sh /Users/almirsarajcic/Areas/Kogen/delivery/kogen-loop` (a clean checkout at 33e7f4ec). Never hand-edit vendored bytes; the script excludes `.kogen/` and `features/`. Result: 107 files, byte-equal to `git ls-files` there (minus those folders).
2. Update `cli/loop-pin.json` with the script's output, exactly: `module=kogen-loop`, `protocol=kogen-loop/v1`, `library=loop/v1`, `digest=3f99ae913cfe08c356bc0543746ae0ebf581880531081633e8d23559d0a74c2c`, `files=107`, `source_head=33e7f4ec8ba899fc4aa621127379e5cb26b77648`, `source_state=clean` (previously 88 files, digest `4e1332b9...946638`). `TestLoopPin` passes unchanged in meaning.
3. Probe parity: in `cli/verify/probe.go` pass the probe's context as `sys.Options.Context` in addition to `Timeout: probeDeadline` and `Env`. Keep the 5-minute deadline and the unchanged `ProbeResult` (`Status`, `TimedOut`, `Output`, `Wall`, `InputChanges`). A short deadline still gives `TimedOut: true`; a cancelled context stops the run (cancellation, session interrupt and hook errors keep their current precedence).
4. Error parity: a failed or unsupported timeout observation returns `sys.ErrTimeoutObservation` (a plain error, `errors.Is`). Probe, Shape probe tool and Refine probe tool must report it as a failure of the probe/round with a clear message that names the timeout observation failure; it must not be rendered as a timed-out probe result (`timed_out: true`), must not become tool feedback text that looks like a normal probe result, and must not be a generic "error". `errors.Is(err, sys.ErrTimeoutObservation)` must stay true for whatever error reaches the caller.
5. Diagnostics: the loop attaches `provider_failure` to terminal invalid Anthropic Messages responses (`invalid_response`): `{"anthropic_invalid": <category>}` plus one of `error_type`, `stop_reason`, `block_type`, `delta_type`, unknown or ill-typed values replaced by `unknown`, and a `provider failure: <JSON>` line in the error. Kogen already carries `sys.Error.ProviderFailure` into the refine result, the shape batch diagnostic and Build `result.json` and outcome events; confirm this for the new map unchanged, with no raw payload added (change code only if a test shows it does not hold). Document the map in `spec/prose/08-chatgpt.md` next to the ChatGPT `provider_failure` paragraph (or an Anthropic counterpart chapter), including that the contract says these diagnostics do not change retry or validity decisions. Decision for `cli/usage.go`: it reads only `provider_failure["code"]`, so an `anthropic_invalid` map yields `provider_failure_code: null`; that STAYS (diagnostics never change retry or validity, and the usage allowlist is not widened beyond bounded identifiers), and a test covers it.
6. Docs: leave `docs/evidence/extract-loop-executors/README.md` history intact; add a new short evidence file under `docs/evidence/` (for example `docs/evidence/k5-loop-repin/README.md`) naming commit 33e7f4ec…, 107 files, the new digest, the Linux timeout repair, and keeping the note that `cli`'s `./...` does not cover `cli/third_party/kogen-loop` (the nested module is tested with `(cd cli/third_party/kogen-loop && go test -race -count=1 ./...)`). Update other docs that name the pin only where they state the current pin.

Must stay: no arbitrary timeout default — every Kogen `sys.Options{}` without a timeout stays unbounded (git, setup, configured checks, `build.go` check runs, the native shell tool); `tools.Tools.ShellTimeout` is not set anywhere; the new library-only `ShellTimeout`, `Tools.Definition`, `RunContext`, `CallContext` are not adopted; shell tool text stays "Commands have no time limit." and native request bytes are unchanged. Native tool/request bytes, last-terminal behavior, transcript/checkpoint compatibility, resume and recovery, the single generic implementation, approval/custody/verification/review and the single commit are unchanged. `.kogen/project.yaml` is not edited. `cli/executor_wiring_test.go` and `cli/build/executor_native.go` must still compile and pass without wrapper changes (the loop now calls `Tools.CallContext`); add a wrapper only if the build proves it necessary and say why.

Host safety: never stop processes by name or pattern (no `pkill`, `killall`, `kill $(pgrep ...)`); stop only process ids your own command started; use random free high ports; never touch PostgreSQL clusters or other databases.

Verification expected: all configured checks green on Darwin and Linux (on Linux `TestZshDynamicWiring` needs `zsh`; a host without it is a host gap), and the nested-module race test passes on both, including `TestToolsMatchTheElixirResults`.

## Decisions
- Pin exactly 33e7f4ec8ba899fc4aa621127379e5cb26b77648, 107 files, digest 3f99ae91…4c2c, produced only by the sync script (source: request)
- Probe passes its context as `sys.Options.Context`; deadline stays 5 minutes; `ProbeResult` unchanged (source: request)
- `sys.ErrTimeoutObservation` is reported as a probe/round failure with a clear message by Shape, Refine and the probe (source: request)
- Anthropic `provider_failure` map flows unchanged to refine result, shape diagnostic, Build result and outcome; no raw payload (source: request)
- Usage keeps `provider_failure_code: null` for `anthropic_invalid` maps; allowlist not widened (source: request)
- No new timeout defaults; `ShellTimeout` not adopted (source: request)

## Source comparison
- Re-pin items 1–2 (script, 107 files, digest, head, state): addressed by acceptance scenarios 1–2 (pin identity via independent hashing, byte comparison with the clean checkout when present at /Users/almirsarajcic/Areas/Kogen/delivery/kogen-loop or KOGEN_LOOP_SOURCE) and `TestLoopPin`.
- Probe parity (item 3): addressed by `TestProbeDeadlineStopsTheProbeAndReportsTimedOut`, `TestProbeCancelledContextStopsTheCustodyWait` and a source check for `Context:` plus the retained `Timeout: deadline`.
- Error parity (item 4): addressed by verify and Shape/Refine tests listed below.
- Diagnostics (item 5): addressed by refine/shape/build tests, `spec/prose` check and the usage test; decision stated (stays null).
- Docs (item 6): addressed by the new evidence note check; old evidence history preserved.
- Must-stay list: addressed by the source check for no `ShellTimeout` outside the vendored module and by existing native tests (`TestNativeDescriptor`, `TestNativeConformance`); the Darwin/Linux platform runs, review approval, and no-diff-timeouts review are final verification, not Gherkin.
- Omitted: running the sync script itself is the Build's work, not an acceptance step; platform-specific Linux runs cannot be executed from one host acceptance.

## Tests
- Pin is the exact 107-file tree and identity: independent hash/identity scenario and byte comparison scenario (scenario)
- Pin consistency with the files: `TestLoopPin` (existing)
- Probe still reports TimedOut on a short deadline: `TestProbeDeadlineStopsTheProbeAndReportsTimedOut` (existing)
- Probe stops on a cancelled context with Context set: `TestProbeCancelledContextStopsTheCustodyWait` in cli/verify/probe_deadline_test.go (unit)
- Timeout observation failure is a probe failure, `errors.Is(err, sys.ErrTimeoutObservation)`, not a timed-out result: `TestProbeTimeoutObservationFailureIsNotATimedOutResult` in cli/verify (integration)
- Shape and Refine report it with a clear message: `TestShapeProbeReportsTimeoutObservationFailure`, `TestRefineProbeReportsTimeoutObservationFailure` in cli/shape (integration)
- Anthropic map reaches refine result and shape diagnostic without raw payload: `TestRefineAnthropicInvalidProviderFailureReachesTheResult`, `TestShapeAnthropicInvalidProviderFailureReachesTheDiagnostic` in cli/shape (integration)
- Anthropic map reaches Build result.json and outcome event: `TestBuildAnthropicInvalidProviderFailureReachesResultAndOutcome` in cli/build (integration)
- Usage yields null code for the Anthropic map: `TestUsageLeavesAnthropicInvalidProviderFailureCodeNull` in cli (unit)
- Spec prose documents the map and usage decision; evidence note exists; no ShellTimeout; probe source passes Context: documentation scenario (scenario)
- Native bytes and wrapper compile/pass unchanged: `TestNativeDescriptor`, `TestNativeConformance` (existing)
- Nested loop module: `TestToolsMatchTheElixirResults`, `TestEngineOrder` (existing)

## Feasibility
- none
