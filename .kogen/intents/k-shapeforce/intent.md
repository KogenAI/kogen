# Force submit after tool-free shaping turns

Slug: k-shapeforce
Model: .kogen/intents/k-shapeforce/model.qnt invariants=bounded,forcedHasCause seed=1 samples=100 steps=20
Acceptance:
- .kogen/intents/k-shapeforce/acceptance.feature
- features/steps/k_shaperetry_steps.js

Native Shape and Refine must request the terminal submission tool at API level on the inference immediately after an answer containing zero tool calls. Shape targets `submit`; Refine targets `submit_refinement`. Replace charging these answers to the invalid-submission budget with a separate no-tool counter. Discovery calls without submit are not no-tool answers. A forced request applies for one inference only; another tool-free answer schedules another forced inference. Never force the first inference or an inference following an ordinary tool-bearing answer.

Keep the existing invalid-submission default of 3, its existing internal override semantics, and all submission validation/readiness/publication rules. Preserve the existing finite protection against repeated prose: stop at 3 no-tool answers (separate from invalid submissions), with an explicit no-tool exhaustion diagnostic rather than claiming three submissions were refused. Do not increase any timeout, retry or limit. Both counters are invocation-cumulative, including local working-context resets; reset handoffs must retain them and pending force state without changing normal request bytes.

Add optional per-request named-tool selection to the loop provider interface if needed: the pinned Request currently has none. Reuse existing loop support where available. An unset selection must render exactly the previous request bytes and headers, including provider defaults, tools, cache identity and replay. Responses uses `tool_choice: {"type":"function","name":"submit"}` (or `submit_refinement`); Chat Completions uses `{"type":"function","function":{"name":"submit"}}` with the corresponding Refine name. Retain the complete existing tools and conversation. Anthropic's current adaptive-thinking route is a reminder-only fallback: do not disable thinking or change model/effort to force tools. External executors without API tool-choice control likewise retain their existing feedback path, without claiming a forced wire request. Do not add a paid capability probe, route sweep, automatic provider fallback or retry on rejection. Provider errors remain honest errors. Follow the existing loop-copy convention: if the component must change, prepare a temporary component checkout and use `packaging/sync-kogen-loop.sh` to update the copy and `cli/loop-pin.json` together.

For reminder-only requests preserve exactly today's messages: Shape `End by calling submit with either questions or files.`; Refine `Call submit_refinement with a nonempty files array of complete existing owned artifact contents (edits or readiness acknowledgment), or constraint.` Record the lack of API support in the run log. For supported routes API selection, not reminder text alone, must enforce the target. A forced submission is validated identically to any other submission; refused payloads still spend an invalid-submission attempt.

Record a `forced_submit_turn` shaping event for every next-turn enforcement request, with owner (`shape`/`refine`), target tool, provider, whether API forcing is supported, and both current counters. On each invocation exit (success, validation exhaustion, no-tool exhaustion or provider error), record a `shaping_turn_counts` event with owner, `no_tool_turns` and `invalid_submissions`; increment invalid submissions for the final refusal too. Keep this separate from historical readiness observations. No CLI or `.kogen/project.yaml` change.

## Decisions
- Recover a prose-only answer by requiring the submission tool on the next turn, while retaining reminder-only fallback for providers without that capability. (source: request)
- Keep refused submissions limited as today, and make no-tool turns and forced turns visible separately. (source: request)

## Source comparison
- Addressed: request What 1–3 and fake-provider examples are covered by the next-turn wire policy, separate counters and events above, and the executable cases in acceptance.feature. Current shape.go and refine.go charge zero-call responses to invalid submissions; that accounting is superseded.
- Addressed: Must stay is preserved by unset-choice byte identity, unchanged validation/default invalid limit, unchanged CLI/configuration and no increased resource limits. The separate three-no-tool ceiling retains bounded prose recovery rather than introducing unlimited retries.
- Addressed: Host safety applies to all fixtures: temporary directories only, no synthetic CPU load, no process-name/pattern termination, and cleanup only of processes the fixture started.
- Addressed as post-landing research, not deterministic qualification: the request's goose-labels-go and documentation-lookup-evidence on terra medium should drop to near 0 no-submit, from the supplied 8/8 and 10/16. Do not claim this gate passed from fake-provider tests or run those research jobs during Build.
- Context retained: the supplied 28 Oct 2026 research found 38/970 no-submit sessions, all below 45k tokens (terra 30/226, sol low 8/277, Claude 0/427), and L-TTL exhausted the old three-attempt accounting. These are historical motivation, not new runtime thresholds.
- No requested product behavior is intentionally omitted. Protocol documentation retrieval returned truncated bodies and one unsupported URL; this is not live qualification of selected providers/models.

## Tests
- Prose followed by a valid forced submission succeeds in native Shape and Refine with counters 1 and 0: add TestShapeForceRecovery using real Shape/Refine entry points and local scripted HTTP provider, valid discovered Intent/correction and normal readiness acknowledgment where needed (regression)
- Unsupported forcing preserves exact reminder and logs unsupported status: add TestShapeForceFallback for the adaptive-thinking provider route and external feedback fallback using existing fixtures (integration)
- Three refused submissions still stop, even following a prose answer, and final counts include the last refusal: add TestShapeForceInvalidBudget and retain TestSubmissionRetryDefault (integration)
- Ordinary sessions keep byte-identical rendered requests, and forcing is next-turn-only with the correct wire shape: add TestShapeForceWireCompatibility covering Responses and Chat Completions, normal discovery, forced submission, then ordinary continuation (integration)
- Repeated no-tool responses remain bounded independently and resets preserve accounting/pending enforcement: add TestShapeForceNoToolBound covering both native owners, no fourth inference after three prose responses, and existing working-window machinery (integration)
- All configured checks remain unchanged and pass: run the configured format, compile, test, go-test, spec and cucumber checks (existing)

## Feasibility
- Repository inspection found fixed auto choices in the pinned renderers and no request-level named selection; component updates are feasible through the existing sync script without editing protected inputs.
- Documentation search results were retrieved but did not discover relevant specific protocol sources. Fetch https://platform.openai.com/docs/api-reference/responses/create was unsupported. Fetches of https://developers.openai.com/api/reference/resources/responses/methods/create and its /index.md, and https://platform.claude.com/docs/en/agents-and-tools/tool-use/implement-tool-use were retrieved, untrusted and truncated; no live provider support is claimed.
- Quint typecheck succeeded in the scratch probe; the reused acceptance observer printed accepted for its good control and rejected with exit 1 for its bad control. The first probe was refused because its scratch input used an absolute path; no check ran in that attempt.
- evidence: {"id":"test-observer","kind":"observer","inputs":["features/steps/k_shaperetry_steps.js"],"observers":["features/steps/k_shaperetry_steps.js"],"checks":[{"name":"good","command":"node features/steps/k_shaperetry_steps.js good","exit":0,"output":"accepted\n"},{"name":"bad","command":"node features/steps/k_shaperetry_steps.js bad","exit":1,"output":"rejected\n"}]}
