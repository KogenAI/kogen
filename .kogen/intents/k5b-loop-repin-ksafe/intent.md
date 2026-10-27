# Re-pin kogen-loop and use its process-group safety

Slug: k5b-loop-repin-ksafe
Model: not applicable — a vendored-source update plus option flags; no state machine
Acceptance:
- .kogen/intents/k5b-loop-repin-ksafe/acceptance.feature
- features/steps/k5b_loop_repin_ksafe_steps.js
- features/steps/k5b_probe_driver.go
- features/steps/k5b_build_check_driver.go

Re-pin `cli/third_party/kogen-loop` from 33e7f4ec to `2ea31bf5438f0bdde537848f678a7331c5fe2a2a` ("Sweep command groups and refuse foreign kills" plus "Retry transient provider stream faults") and use the loop's new process-group safety in Kogen. A Shape probe once ended with `pkill -f beam.smp`, which would have killed live services on the host.

1. Run `sh packaging/sync-kogen-loop.sh /home/delivery/src/kogen-loop` (a clean checkout at 2ea31bf5; also in `KOGEN_LOOP_SOURCE`) and write its output to `cli/loop-pin.json`: `module=kogen-loop`, `protocol=kogen-loop/v1`, `library=loop/v1`, `digest=0f2daaefc9f0c6c22851dc29df1f774a7d8c863261200eac16e1489435cecec1`, `files=111`, `source_head=2ea31bf5438f0bdde537848f678a7331c5fe2a2a`, `source_state=clean`. Never hand-edit vendored bytes. Add a short evidence note under `docs/evidence/` (for example `docs/evidence/k5b-loop-repin/README.md`) naming the commit, 111 files and digest; leave older notes (including `docs/evidence/k5-loop-repin/`) intact.
2. Probes (`cli/verify/probe.go`): add `KillGroupOnExit: true` and `RefuseForeignKill: true` to the probe's `sys.Options`. A refused probe command is an ordinary probe result: `Status` 126, `TimedOut` false, `Output` exactly `sys.RefusalText(rule)` (which names the rule), no Go error, and the Shape or Refine round continues. `Status`, `TimedOut`, `Output`, `Wall`, `InputChanges` keep their meanings and the 5-minute probe deadline stays. Use only the loop's `sys.ForeignKill` (through `RefuseForeignKill`); no second implementation.
3. Every other `sys.Options{}` Kogen itself uses outside tests and `third_party` (setup, fix, configured checks and acceptance in `cli/build` and `cli/verify`, hooks, git commands run through the session): set `KillGroupOnExit: true`. Do not set `RefuseForeignKill` there (those are the user's configured commands). Add no `Timeout` anywhere.
4. The native shell tool is the loop's own: change neither its options nor its text; request bytes, tool definitions, transcripts and checkpoints are unchanged.
5. Document plainly in `spec/prose/02-shaping.md` (the SHP-10 probe paragraph) and `docs/executor-contract.md` what Kogen enforces (probe refusal, process-group sweep of Kogen-run commands, round/engine cleanup) and what it cannot enforce for the Claude Code executor: its own Bash runs outside Kogen's `sys.Session.Run`; a Bash PreToolUse hook using `sys.ForeignKill` is a separate item, K-SAFE-2; processes that leave the group with `setsid` are not reached.

Must stay: no new timeout default; approval, custody, verification, independent review and the single commit unchanged; `.kogen/project.yaml` not edited. The acceptance reads the clean checkout from `KOGEN_LOOP_SOURCE` and fails with a clear message when it is unset; no machine-specific default path appears in committed files. Host safety: never stop processes by name or pattern except the test's own uniquely named sibling; stop only recorded process ids.

## Decisions
- A refused probe is a normal result with status 126 and the loop's refusal text, not a timeout or Go error (source: request)
- Configured commands sweep their group but never refuse foreign kills (source: request)
- Docs go in SHP-10 of `spec/prose/02-shaping.md` and `docs/executor-contract.md` (source: request)

## Source comparison
- Re-pin to 2ea31bf5, 111 files, digest and pin JSON literals: addressed by scenario 1 and the Intent contract.
- Probe options, refusal result, rules for pkill, killall and kill of a sibling pid, round continuation: addressed by the outline scenario.
- Group sweep for a probe and for a configured check through cli/build: addressed by two scenarios (the check is driven by an overlay test of Build's pre-change check step).
- Short deadline still TimedOut: addressed.
- No Timeout, no RefuseForeignKill elsewhere, ProbeTimeout kept: addressed by the source scenario.
- Docs and evidence note: addressed by two scenarios. Not covered by an executable check: the native shell tool, tool definitions, request bytes, transcripts and checkpoints stay unchanged (existing tests); the Linux and Darwin full configured checks run in the Build gate.
- Portability: KOGEN_LOOP_SOURCE required with a clear failure message; no default path.

## Tests
- Vendored copy byte-equal to 2ea31bf5, 111 files, exact loop-pin.json, TestLoopPin: scenario 1 (scenario)
- Probe refuses pkill, killall and kill of a sibling and continues: outline scenario (integration)
- Probe and configured check leave no background group member, status and output unchanged: two scenarios (integration)
- Short probe deadline still times out: scenario (existing)
- Options flags and no new timeout in Kogen sources: source scenario (unit)
- Spec prose, executor contract and evidence note: two scenarios (existing)

## Feasibility
- Overlay and driver approach follows the existing review-efficiency and go-driver patterns; sys.Options.KillGroupOnExit, RefuseForeignKill and Result.Rule were read in the loop source at 2ea31bf5. (read: no probe needed)
