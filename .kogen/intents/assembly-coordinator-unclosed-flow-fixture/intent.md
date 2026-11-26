# Isolate the unclosed flow fixture

Slug: assembly-coordinator-unclosed-flow-fixture
Model: not applicable — a single fixture input changes, not behavior or state
Acceptance:
- .kogen/intents/assembly-coordinator-unclosed-flow-fixture/acceptance.feature
- features/steps/assembly-coordinator-unclosed-flow-fixture__steps.js

Repair the release-blocking Coordinator consumer fixture. Change only the input literal of `TestParseConfigRefusalsAreSysErrorsWithLines/unclosed_flow` in `cli/consumes/kogen-coordinator/config_test.go`. Keep every existing assertion; leave the separate `ReadableConfig` fixture untouched. The Build and independent review should see only that one source line change outside the Intent's acceptance artifacts.

## Decisions
- Replace the tab-indented unknown key in the targeted input with unindented `commands`, so the only input defect is the missing flow sequence terminator; preserve the exact expected line and rendered error, including class and reason, the structured error type, nil config, filename, and exit 3. (evidence: cli/consumes/kogen-coordinator/config_test.go; .kogen/project.yaml) (source: request)
- Do not change Coordinator code, pin or YAML parsing behavior, and do not weaken any acceptance or qualification checks. Make no other source changes or existing fixture rewrites. (source: request)
- Run the full Coordinator consumer package from `cli` on main's unchanged pin for Build acceptance. After landing, Release/Recovery runs the same package on the retained exact candidate pin `b5b23ff5738a`, then runs the normal full release gate without weakening any check. These are required release operations, not a pin edit, not part of pre-landing Build acceptance, and not satisfied by a main-pin pass or earlier isolated results. (evidence: cli/go.mod; cli/consumes/kogen-coordinator/README.md; .kogen/project.yaml) (source: request)
- Use ordinary `chatgpt-full` delivery because registered Claude Team reserve is closed; use normal dispatch and capacity gates. This is an operational route instruction, not a change to model or project configuration. (source: request)

## Source comparison
- Addressed: the request's exact replacement Go literal and original diagnostic are in the scenario's source assertion, alongside the existing refusal checks. The old tab-indented input is superseded only at the row named `unclosed flow` (`config_test.go`); the similar `ReadableConfig` fixture is not in scope.
- Addressed: acceptance (1) checks the tracked source, not a substitute parser fixture; acceptance (2) exercises the real consumer suite using `go test -count=1 ./consumes/kogen-coordinator` from `cli`. The single-source-line decision and unchanged pins/checks apply to the final diff.
- Addressed separately: acceptance (3) is the mandatory post-landing Release/Recovery handoff in Decisions and the feature description. The user reports isolated passes on both pins; they are historical evidence, not proof that the retained candidate or full release gate has been verified after landing. No release procedure is replaced or implemented by this Intent.
- Addressed: ordinary `chatgpt-full` and unchanged dispatch/capacity gates are operator instructions in Decisions and the feature description, not build changes. No requested scope is omitted.

## Tests
- Isolate the unclosed sequence while preserving the refusal contract: `TestParseConfigRefusalsAreSysErrorsWithLines/unclosed_flow` and the scenario's exact source assertion (regression)
- Preserve the complete Coordinator consumer contract on the unchanged pin: run the existing consumer package from `cli` (existing)

## Feasibility
- The unmodified package passes on main's Coordinator pin `v0.0.0-20261123070705-a5e054b57738` with Go 1.27.2; the regression red on main must therefore come from the source assertion, not an expected parser failure. The real Go JSON stream has a named subtest pass and a package pass; a zero-test run can emit the latter by itself.
- evidence: {"id":"coordinator-runner","kind":"observer","inputs":["cli/go.mod","cli/consumes/kogen-coordinator/config_test.go"],"observers":["features/steps/assembly-coordinator-unclosed-flow-fixture__steps.js"],"checks":[{"name":"good","command":"node features/steps/assembly-coordinator-unclosed-flow-fixture__steps.js","exit":0,"output":""},{"name":"bad","command":"GOFLAGS='-run=^$' node features/steps/assembly-coordinator-unclosed-flow-fixture__steps.js","exit":1,"output":"go test -count=1 ./consumes/kogen-coordinator: TestParseConfigRefusalsAreSysErrorsWithLines/unclosed_flow did not run and pass, or the package did not pass\n"}]}
