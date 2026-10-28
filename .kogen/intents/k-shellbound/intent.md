# Add opt-in native shell time bounds

Slug: k-shellbound
Model: .kogen/intents/k-shellbound/model.qnt invariants=Safety seed=3 samples=1000 steps=20
Acceptance:
- .kogen/intents/k-shellbound/acceptance.feature
- features/steps/kshellbound_steps.js
- features/steps/kshellbound_driver.go

Add optional top-level `tool_shell_timeout_seconds: <positive integer>` in `.kogen/project.yaml`. Absence retains today's unbounded behavior. Validate at config load, naming the key for zero, negative, non-integer and nested-map values, including unknown nested keys. Preserve the setting through configuration rendering. Convert seconds safely to the native duration; reject an unrepresentable duration rather than wrapping it into an unbounded or different limit.

Pass the configured duration as `tools.Tools.ShellTimeout` for every native model-issued shell call in Build and independent Review, using that same configured tool instance's `Definition` method for shell definitions. Preserve ordering and all other tool definitions. Shape/Refine currently expose probes rather than shell: do not add shell tools to them and do not change probes or worker probes. If a native role already exposes shell, the common shell policy applies. This is per invocation, not a provider, batch, round or whole-Build deadline. Use the pinned library's ordinary timeout feedback and custody, not an adapter timer. Proven timeout feedback starts `timed out after 1s` for value 1 and reaches the model in ordinary paired/replayed tool output; the Build may continue. Commands finishing before their bound retain their exact ordinary result. Interruption and context cancellation remain stopping errors, never timeout feedback. Preserve the library's observation-error behavior rather than inventing successful timeout feedback.

Update `docs/configuration.md`, specification prose LOOP-5/LOOP-11 and related setting text, `spec/features/04-building.feature`, its vocabulary/fake-provider conformance support, and `spec/quint/run_control.qnt` as needed: unbounded unless explicitly opted in, timeout feedback only after owned group teardown, and cancellation stops rather than producing timeout feedback. Add executable conformance replay of both default-unbounded and opt-in behavior. Amend existing specification models rather than merely adding the Intent model. Kogen's configured setup/fix/check/acceptance commands (and other existing verification execution) keep their existing behavior. The external `claude-code` executor is unchanged and the guide explicitly says the key does not apply there.

With the key absent, definitions, results, provider requests and retained replay bytes must be byte-identical to today's. Keep existing byte/golden conformance tests unchanged for that case and add targeted default-request/replay compatibility coverage where needed. Do not edit `cli/third_party/kogen-loop` or `cli/loop-pin.json`. No other timeout, budget or limit changes, command, flag or output. Run all configured checks. All process fixtures use temporary directories and only their own pids/groups, with no process-name/pattern termination or synthetic CPU load.

## Decisions
- The setting is opt-in and absent means unbounded, with no new command, flag or output. (source: request)
- The setting applies only to native shell calls; Shape/Refine probes and enabled Shape-worker probes retain their five-minute behavior and structured results. Document that exclusion explicitly. (source: answer 1)
- External claude-code execution and Kogen's configured project commands are unaffected. (source: request)

## Source comparison
- addressed: request What 1 and Acceptance invalid values → configuration paragraphs, validation outline and implementation unit tests below; literal `.kogen/project.yaml`, `tool_shell_timeout_seconds` and `docs/configuration.md` retained. The repository's own protected project.yaml need not be edited to support this optional key.
- addressed: What 2 and supplied `sleep 3`, value 1, `timed out after 1s`, continuing Build, early ordinary results and whole-process-group custody → native wiring paragraphs and executable Build/Review scenarios. No pinned-library implementation change is authorized.
- superseded: request What 1's initial inclusion of Shape/Refine command execution → answer 1 explicitly excludes probes including worker probes; acceptance documentation scenario and Decisions preserve the settled scope without adding shell tools.
- addressed: What 3 and spec conformance replay → LOOP-5/LOOP-11 prose, feature/vocabulary/fake-provider updates and existing run_control Quint model, plus the executable conformance gate. The standalone library's nonpositive-off API is not permission for nonpositive project configuration.
- addressed: What 4, Must stay and Acceptance all configured checks → unchanged claude-code route, configured commands, default byte compatibility and pinned files; Tests require existing golden/replay and all configured checks. No other timeout/budget changes or new output.
- addressed: Host safety → temporary-fixture execution and pid/group-only operations. Historical rationale (kogen-loop 84c427d pinned via c7e8331, LONG-STALL approximately 3560 s, caller-shell-bound and provisional 28 Oct ordering) explains the opt-in, not a new roadmap/scheduler or a mandate to shorten legitimate long commands. No requested behavior is intentionally omitted.
- addressed: correction payload audit → `features/steps/kshellbound_driver.go` now passes `approve`, not `approved`, to `submit` in `cli/build/review_test.go`, which emits `submit_review` with an empty findings array accepted by `cli/build/review.go`'s validator. Shell command strings match `cli/third_party/kogen-loop/tools/defs.go`; reused `landScript` in `cli/build/build_test.go` supplies valid write_file path/content and finish summary strings. `cli/build/helper_test.go` serializes these as paired function calls and SSE responses. The JavaScript steps emit no provider calls, Shape submissions or read_file calls; their filesystem reads and subprocess arguments are unchanged. Every assertion, scenario, model and product requirement above is retained.
- omitted: none of the requested correction or original settled scope intentionally omitted. Conflicting: the old `approved` verdict conflicts with the validator and is replaced only in the scripted Review payload. Superseded: that invalid fixture literal only; no approved product behavior is superseded by this correction.

## Tests
- Positive whole-second configuration, omission and invalid values including nested keys: LoadConfig acceptance outline and focused ParseConfig/RenderConfig unit tests, including 1 and 2 and the representable-duration boundary (unit)
- Native Build receives ordinary unbounded `sleep 3` output, bounded timeout feedback and unchanged early completion: real Build with local fake provider and successive tool calls (integration)
- Timeout stops the whole owned group before the next model request and permits continued work: group fixture observed at the next provider request, not after Build cleanup (integration)
- Independent Review uses the same configured duration and definitions: real native reviewer with local fake provider (integration)
- Interrupt remains run-stopping and produces no timeout feedback: interrupt the owned session after its shell has started (integration)
- Context cancellation remains a stopping error: preserve existing TestNativeRoundMapsCancellationButKeepsTheSessionsInterrupt and add positive-bound coverage there (integration)
- Shape/Refine and worker probes, project commands and external claude-code retain existing behavior: guide assertions plus existing role/probe/executor tests and targeted configured-command execution lasting beyond the shell bound (integration)
- Absent configuration preserves tool, request and replay bytes: existing golden/conformance tests unchanged and targeted fake-provider default compatibility assertions (regression)
- Specification describes and replays the caller opt-in without changing the default: amend LOOP-5/LOOP-11 scenarios and run_control model, run spec check and deterministic chapter-04 installed conformance (scenario)
- No pinned library or pin edits, new flags or unrelated limits: existing configured checks and final changed-tree review (existing)

## Feasibility
- Repository evidence: pinned caller contract `cli/third_party/kogen-loop/docs/contract/loop-v1.md` specifies Tools.ShellTimeout, instance Definition, exact ordinary/timeout output and cancellation precedence; no external provider or protocol change is required. Build executor_native.go and review.go currently construct unbounded Tools and definitions separately.
- A focused temporary pinned-library test with ShellTimeout=1s and `trap 'wait; exit 143' TERM; sleep 3 & wait` returned timeout feedback on this Linux host (probe: exit 0, 2.5 s). This is local support evidence, not supported-platform release qualification. Existing caller-definition/ordinary-result tests also passed (probe: exit 0, 1.4 s). No CPU-loop tests were run.
- The Intent model typechecked and its two tests passed with the TypeScript backend (probe: exit 0, 1.0 s).
- evidence: {"id":"observer","kind":"observer","inputs":["features/steps/kshellbound_steps.js","features/steps/kshellbound_driver.go"],"observers":["features/steps/kshellbound_steps.js"],"checks":[{"name":"good","command":"node features/steps/kshellbound_steps.js --control good","exit":0,"output":"kshell observer accepts good fixtures\n"},{"name":"bad","command":"node features/steps/kshellbound_steps.js --control bad","exit":23,"output":"kshell observer rejects bad fixtures\n"}]}
