# Wire internal native round limits per role

Slug: k-nrounds
Model: not applicable — this wires the pinned loop's existing request-count state machine into native role settings; it adds no new state machine
Acceptance:
- .kogen/intents/k-nrounds/acceptance.feature
- features/steps/k_nrounds_steps.js

Expose an internal research-only per-role native round limit, with zero meaning unlimited. Use `NativeRoundLimits map[string]int` on build.Deps and shape.ShapeInput (and the corresponding native Refine input), keyed by `shape`, `build`, and `review`. A lane patch can set a role in one line. Keep these settings out of CLI parsing and project.yaml. Apply the selected limit only to native roles already using loop.Run/loop.Round today: the native Build role. Pass its `build` limit to loop.Round.MaxRounds. Shape, Refine and Review retain their own request loops unchanged: their map keys are ignored, not accepted as effective limits, and unsupported for now. Do not refactor them onto the pinned round engine. Limits count provider requests in one native Build loop invocation, not verification passes, tool calls, transport attempts, or all roles combined. Completed terminal/no-call responses at the boundary remain normal endings per the pinned loop contract.

A continuing native Build loop reaching its positive limit follows its existing error/stop path, without a new user-facing output format. Record an event `native_round_limit` containing `role`, `limit`, and `rounds` in the role's existing record; preserve a truthful round-limit reason. Record this event only when the cap actually stops continuation. There must be no further request, commit, or successful approval from that stopped role. Existing explicit continuation rules remain unchanged.

Zero settings must preserve today's requests, records, and behavior byte-for-byte (apart from already nondeterministic IDs/timestamps); in particular do not serialize empty settings or add zero-limit events. No CLI flag, project.yaml key, changes to executor claude-code max_rounds, other limits, cli/third_party/kogen-loop, or cli/loop-pin.json. Add a short developer note or code comment identifying the option as internal and research-only and explicitly documenting Shape, Refine and Review limits as unsupported for now, with their map keys ignored. Use local fake providers only. Shared-host work must use temporary directories and never stop processes by name/pattern or generate CPU load; terminate only processes started by the test.

## Decisions
- Internal per-role option; default zero; no public configuration surface (source: request)
- Stop through existing paths with truthful role/limit recording, not a new display format (source: request)
- Only native Build consumes the setting; no Shape, Refine or Review loop refactor (source: request)

## Source comparison
- Addressed: original internal role-keyed option and input interfaces, default-zero byte-identical compatibility, request counting, truthful stop/event recording and terminal/no-call boundary behavior remain required above and in Tests.
- Addressed: correction narrows effective limits to native Build, the existing loop.Run/loop.Round consumer in cli/build/executor_native.go. Shape, Refine and Review keys are ignored and documented as unsupported for now; their bespoke loops remain unchanged.
- Superseded by correction: original paragraph requiring Shape/Review integration onto the pinned round engine and original Tests requiring each native role to obey a cap. Build limit tests replace those cross-role cap tests; unchanged-role tests protect existing behavior.
- Addressed: supplied Build limit 2 reproducer and shape/review-only counterexample remain executable in acceptance.feature and features/steps/k_nrounds_steps.js. Limits 1 and 3 and terminal-at-boundary cases remain implementation integration requirements below.
- Addressed: original exclusions remain: no CLI/yaml surface, unchanged Claude Code max_rounds and other limits, no cli/third_party/kogen-loop or cli/loop-pin.json edits; local fake providers and shared-host temporary-directory/process safety remain required.
- Omitted from implementation scope, unchanged: research catalogue outputs/_internal/MECHANISMS.md loop-round-limit, climb M4 and the provisional 28 Oct scheduling note are motivation, not additional files or research execution requirements. The correction identifies climb M4's research need as native Build.
- Conflicting: original cross-role engine migration conflicts with the correction and is superseded only as stated above; no other original behavior is superseded. Diagnostic provenance was unavailable at the supplied repository-relative location during this correction; the full supplied contract and owned originals were inspected directly, not reconstructed from that receipt.

## Tests
- Default zero preserves fake-provider Build requests and records: keep existing Build record and landing tests unchanged; compare explicit zero and omitted options with dynamic fields normalized only (integration)
- A continuing fake native builder stops at limit 2 with recorded role/limit/reason and no commit: protected overlay driver (integration)
- Unsupported Shape/Review settings do not cap Build: protected overlay driver runs three build requests with only those other roles set (integration)
- Native Build obeys its cap: add fake-provider tests at limits 1, 2 and 3 asserting request counts, retained truthful reason and role/limit event (integration)
- The terminal and no-call response at the cap ends normally with no native_round_limit event: add native Build boundary tests, including one continuing response immediately below the cap (integration)
- Shape, Refine and Review ignore their limit keys and preserve existing behavior: retain existing validation, custody, request preparation, replay and stop tests and add focused omitted-versus-configured fake-provider comparisons for those inputs (integration)
- Zero has no new records or public settings and Claude Code retains max_rounds semantics: existing role/config/executor tests plus explicit omitted-versus-zero comparison (integration)
- All configured checks continue to pass: configured verification suite (existing)

## Feasibility
- The pinned local kogen-loop contract explicitly supports Round.MaxRounds, zero unlimited, RoundLimitError and normal terminal/no-call endings at the boundary; no external provider capability changes are required. Native Build already uses that engine; no migration of other roles is needed.
- evidence: {"id":"observer","kind":"observer","inputs":["features/steps/k_nrounds_steps.js"],"observers":["features/steps/k_nrounds_steps.js"],"checks":[{"name":"good","command":"node features/steps/k_nrounds_steps.js --control good","exit":0,"output":"observer accepted good\n"},{"name":"bad","command":"node features/steps/k_nrounds_steps.js --control bad","exit":1,"output":"observer rejected bad\n"}]}
