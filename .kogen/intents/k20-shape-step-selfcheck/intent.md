# Check the step code Shape writes before publishing

Slug: k20-shape-step-selfcheck
Model: not applicable — one deterministic check step in the shaping pipeline; no new state machine
Acceptance:
- .kogen/intents/k20-shape-step-selfcheck/acceptance.feature
- features/steps/k20_shape_step_selfcheck_steps.js
- features/steps/k20_shape_step_selfcheck_driver.go

Bad step files caused most blocked or wasted Builds (a fixture expecting one hook event for two calls, fixtures needing two refines, a step using `go run`, which maps exit 2 to 1, so four scenarios could never pass). Today only the readiness red run touches the step code. After this change Shape (native, `cli/shape/shape.go`, and external, `cli/shape/external.go`) runs a **step self-check** on every complete candidate submission *before* readiness and before publication. Readiness, exact red acknowledgment, publication, round limits, timeouts and retries are unchanged; Refine is unchanged; step files of other Intents are never touched or judged.

## What the self-check does
It runs on the candidate package files (the Intent's own step files are the files listed under `Acceptance:` that are in the steps folder `features/steps`), using Kogen's own Node (`ShapeInput.Tools.Node`, else `$KOGEN_NODE`) and Cucumber (`Tools.Cucumber`, else `$KOGEN_CUCUMBER`, used as `NODE_PATH`). Checks, each producing items `{"check":<name>,"target":<string>,"ok":<bool>,"detail":<string>}`:
1. `load` (target: the step file's repo-relative path): the file loads under Kogen's Node with Cucumber resolvable (syntax and `require` resolution). detail on failure is Node's error text (it names e.g. `SyntaxError` or the module that cannot be found).
2. `steps` (target: the step text, one item per distinct step text of `acceptance.feature`): exactly one definition matches it, counting the Intent's own step files plus the other files of the project's steps folder as the acceptance command would load them. detail on failure: `undefined step` or `ambiguous step (<n> definitions)`.
3. `definitions` (target: the definition's expression text as written, one item per definition in the Intent's own step files): it matches at least one step of the feature. detail on failure: `unused definition`. Definitions of other files are not judged.
4. `observer` (target: `<evidence id> <check name>`, `good` and `bad`, for every declared feasibility evidence of kind `observer`): the check's command is re-run (same working directory and environment as readiness feasibility checks) and its exit code equals the recorded one. detail on failure: `exit <actual>, recorded exit <recorded>`.
5. `exit_code` (target: the step file's path, one item per own step file): no single step definition both asserts an exit code and obtains it through a wrapper that changes exit codes. A step definition body that mentions `status`, `exitCode` or `exit` and contains `go run`, or `npm run` / `npx` without ` -- ` passthrough, is flagged; a step that builds the binary (`go build`) and runs it is not. detail on failure names the wrapper (`go run`, `npm run` or `npx`), says the step asserts an exit code, and requires the built binary instead.
If a file does not load, checks that need its definitions may be omitted; the `load` item then carries the failure. All items run and are reported together when possible.

## Feedback and evidence
- When any item is not ok, nothing is published and the shaper gets feedback in the same conversation like readiness feedback today (external: `Input.Feedback` of the next round of the same session; native: the tool result of the `submit` call). It starts exactly `Step self-check failed; nothing was published. Fix the step files and resubmit.` followed by one line per failed item: `- <check> <target>: <detail>`. Readiness is not run for that submission (its feedback, `Readiness observations`, does not appear). Existing invalid-submission and round rules apply; no new limit.
- Every self-check records exactly one `step_selfcheck` event in the shaping evidence `events.ndjson`: `{"event":"step_selfcheck","ok":<all items ok>,"items":[<every item checked, ok or not>]}`. A correct package that publishes in one round has exactly one such event and takes no extra round. A corrected resubmission records its own event.
- A correct package whose own step file passes has these items (for the acceptance fixture): load, one steps item per distinct step text, one definitions item per definition, `observer even-observer good`, `observer even-observer bad`, and `exit_code` for the step file.

## Decisions
- The self-check runs before readiness on each complete candidate and failure is feedback, never a publication. (source: request)
- Both native and external Shape run it; Refine and other Intents' step files are out of scope. (source: request)
- Item names, feedback format and the event schema above are fixed by this Intent so that behavior is observable. (source: request)
- `go run`, `npm run` and `npx` are flagged only when the same step definition also asserts an exit code. (source: request)

## Source comparison
- addressed: item 1 bullets — load (syntax and require), exactly-one-definition matching with undefined/ambiguous/unused, observer controls re-run, exit-code wrapper flag (`go run`, `npm run`, `npx` without `--`) requiring the built binary.
- addressed: item 2 — failure becomes feedback to the same conversation; no new round limit, timeout or retry.
- addressed: item 3 — one `step_selfcheck` event listing items and outcomes.
- addressed: acceptance — syntax error, undefined step and `go run` first submissions get named feedback and the corrected second publishes; a correct package publishes with one event and no extra round; observer controls not reproducing recorded exits are fed back (scenarios; the `--` passthrough variants of npm/npx are specified but not exercised).
- addressed: must stay — readiness, acknowledgment, publication, other Intents' protected steps unchanged.
- omitted: "All configured checks pass" is the Build's normal gate, not a scenario. Ambiguous and unused definitions and a failing `require` are added to the scenarios because the request lists them.

## Tests
- each defect (syntax error, failing require, undefined step, ambiguous step, unused definition, `go run` for an asserted exit code, observer exit mismatch) is fed back with its exact line and the corrected package publishes: scenarios 3-9 (scenario)
- a correct package and a built-binary exit-code step publish with one `step_selfcheck` event, all items listed, no extra round: scenarios 1-2 (scenario)
- native Shape behaves the same: scenarios 10-11 (scenario)
- the self-check's item logic (matching, wrapper detection): add unit tests in `cli/shape` (unit)

## Feasibility
- Overlay driver compiles against the unchanged tree and the observer controls behave. (probe 1: good exit 0, bad exit 1, 0.1 s)
- evidence: {"id":"k20-observer","kind":"observer","inputs":["features/steps/k20_shape_step_selfcheck_driver.go"],"observers":["features/steps/k20_shape_step_selfcheck_steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/k20_shape_step_selfcheck_steps.js --control good","exit":0,"output":"k20 observer good\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/k20_shape_step_selfcheck_steps.js --control bad","exit":1,"output":"k20 observer rejected bad fixtures\n"}]}
