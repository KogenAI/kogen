# Prevent executor wakeups outside Build rounds

Slug: k-executor-wakeup
Model: not applicable — tool-availability wiring reuses existing round and Build state machines unchanged.
Acceptance:
- .kogen/intents/k-executor-wakeup/acceptance.feature
- features/steps/extract_loop_executors_steps.js
- features/steps/go_driver_support.js

Prevent Claude Code builders from scheduling later work. Deny `ScheduleWakeup` through Claude Code's existing `--disallowedTools` mechanism on EVERY Build invocation, including feedback invocations using `--resume`. This is internal invocation wiring, not a new Kogen command, flag or option. Preserve existing Shape read-only denials when composing shared arguments. Keep the strict stream protocol, including refusal of events after `result`; do not swallow trailing events or accept second results. Native execution, credentials, limits, timeouts, retries, verification, independent review, checkpoints and commit eligibility remain unchanged.

Bash remains available for long commands, with output and completion status received before the round finishes. Keep the existing background-task disabling policy. Add a concise Build constraint explaining that scheduled wakeups are unavailable and commands must be awaited within the current round. Foreground Bash and a shell waiting for its own child remain sanctioned. No polling cadence is mandated; no timeout is changed. Deterministic fixtures use finite local work, not a real ten-minute wait.

Add editable adapter process/integration tests in `cli/executor/claudecode`: `TestBuildWakeupDeniedEveryRound` observes effective denial in actual first and resumed Build argv without losing existing arguments; `TestBuildLongCommandWithinRound` runs a finite local shell command through the fake session's Bash path and observes stdout, exit status and a completion marker before result, proving Bash is not disabled; `TestBuildTrailingEventStillProtocol` checks malformed input, a duplicate result and an ordinary assistant event after result remain protocol failures. Exercise the adapter and its child process, not just source searches. Retain useful existing tests.

Add editable `spec/features/executor-wakeup.feature`, tagged `@executor-wakeup`, with exactly the three scenario names required by outer acceptance. Use the existing installed-release harness and fake Claude infrastructure under `test/acceptance`, extending them only as needed. Install the archive from configured packaging setup through the normal suite path. An adapter-only invocation or `go run` cannot replace the shipped binary evidence. These production tests, inner scenarios and fixtures are implementation artifacts, not protected Acceptance files.

The scheduled-session fixture models a background command representing full `mix test`, writing to fixture-local `mu-full.log`, then attempting `ScheduleWakeup` with `{"delaySeconds":600,"prompt":"check mu-full.log for failures","reason":"waiting for full mix test run"}`, then StructuredOutput and a success `result`. Without effective denial the fixture emits the next event `{"type":"command_lifecycle","state":"started","wakeup_source":"loop_wakeup"}`, reproducing `executor/protocol: the event stream continued after its result`. With denial the fake reports the tool unavailable/refused, waits for the finite command and observes its output/status within this round, then returns its normal success result without scheduling a continuation. Honor actual received deny rules, not source text, version strings or a success-mode switch. Record the attempted scheduling, denial and command completion before result. This is deterministic integration evidence, not live model qualification.

The installed scheduled-session scenario must land its intended change through normal verification and independent review, preserve the successful builder round claim and have no executor/protocol stop. Filter `executor_round` log records by their actual Build role BEFORE counting builder rounds: independent Review emits the same event name and MUST NOT count as a builder round. Separately confirm independent review ran. The installed long-command scenario must observe command output and exit status before builder finish and successful Build completion. The protocol scenario emits an ordinary assistant event after a valid result (not scheduling, regardless of tool denial), and must stop with executor/protocol, no successful landing and no new commit. Swallowing all trailing events cannot pass.

## Decisions
- Select the request's prevention alternative: scheduled wakeups outside Build rounds are unavailable and long commands are awaited within the round (source: request)
- Add no user-facing command, flag or option and change no timeout, retry or limit (source: request)
- Count builder rounds only, excluding independent Review round events (source: request)

## Source comparison
- Addressed: Need's alternative of preventing scheduling or handling it without round loss is settled to prevention above; other protocol violations remain fatal instead of relaxing the validator.
- Addressed: Evidence's background mix test, output file, ScheduleWakeup delaySeconds 600, waiting-for-full-mix-test reason, StructuredOutput, success result then command_lifecycle started/loop_wakeup are executable fixture requirements above. Fixture-local mu-full.log replaces an unspecified private absolute path, not a claimed original. Event indexes 206/207 of 208 establish historical order, not a required fixture length.
- Addressed: sanctioned long-command waiting and the sleep 590/tail counterexamples (S-MEDIA-INTAKE, S-AUTH-HARDEN) are preserved as within-round waiting; no mandatory polling interval or new scheduler is introduced.
- Addressed: Acceptance evidence uses the shipped binary with an attempted scheduling session. Build 18048b7d's builder-reported acceptance contradiction is explicitly corrected by Build-role filtering before counting and a separate independent-review observation.
- Addressed: nothing else about building changes, with existing configured tests plus negative protocol regression. Historical Build 83c8bb1a, s-migration-unique, MacBook, d42f6cc, Claude Code 2.1.312, claude-sonnet-5-5, 31 Oct 2026 10:54:20Z round 2 are diagnostic provenance, not newly executed live qualification or mandated runtime versions.
- Omitted: no requested product behavior. Superseded: only the possibility of scheduling a later builder wakeup. No failed package, historical review or old green evidence substitutes for fresh verification.

## Tests
- Deny ScheduleWakeup in first and resumed Build invocations: TestBuildWakeupDeniedEveryRound plus installed scheduled-session regression (regression)
- Preserve command output and completion status within the round: TestBuildLongCommandWithinRound plus installed long-command scenario (integration)
- Keep other protocol violations fatal without landing: TestBuildTrailingEventStillProtocol plus installed trailing-assistant scenario (regression)
- Count only Build-role rounds while requiring independent review: installed scheduled-session log assertions (scenario)
- Preserve native execution and existing Build safeguards: configured Go tests and building chapter scenarios (existing)

## Feasibility
- Local probe found Claude Code 2.1.312 and its help documents --disallowedTools/--disallowed-tools as comma- or space-separated tool names to deny (exit 0, 0.1 s). No authenticated live model call was performed.
- Documentation searches returned irrelevant sources. Fetches of https://code.claude.com/docs/en/cli-reference and its .md alternate returned retrieved but untrusted bodies, not trusted qualification. Local CLI help and existing Shape denial wiring establish the interface; new tests prove Build wiring.
- No generated protected observer or driver is added. Existing independent named-test and installed-scenario observers are reused; fixture additions are editable implementation artifacts.
