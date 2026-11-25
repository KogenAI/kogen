# Test the Claude Code runtime platform refusal

Slug: claude-runtime-unsupported-platform-test
Model: not applicable — direct calls return a string without state or transitions
Acceptance:
- .kogen/intents/claude-runtime-unsupported-platform-test/acceptance.feature
- features/steps/claude-runtime-unsupported-platform-test__steps.js

Add focused Go unit coverage in `cli/internal/claudecode/runtime_test.go` for `UnsupportedMessage(goos, goarch string) string`. Use explicit arguments, not the test host's platform; compare the entire returned string against the exact expected text in the feature. The function formats a refusal even when a direct call supplies a supported target; this does not change which platforms can run the runtime. Only the requested test file changes in the implementation. Preserve production code, the supported platform list, runtime installation behavior, and existing tests. Nothing is replaced or removed.

## Decisions
- Keep platform eligibility separate from the direct refusal formatter; assert the exact text including the supplied operating system and architecture without calling the platform gate or invoking installation. (evidence: cli/internal/claudecode/runtime.go) (source: request)
- Verify the added coverage by running the unfiltered Claude Code runtime package test binary against target-specific refusal mutations in temporary Go overlays. (decision: D1, round 1) (constraint: Do not modify the checkout or require a new Go test name.) (evidence: cli/internal/claudecode/runtime.go; cli/internal/claudecode/update_test.go; cli/go.mod; .kogen/project.yaml) (source: request)

## Source comparison
- Evidence `ev-858d1551` is addressed by the direct package unit test specified above and in Tests. The existing test in `cli/consumes/kogen-executor/runtime_test.go` calls the pinned executor dependency, not this package's helper, and remains unchanged.
- Request acceptance 1 is addressed by the Windows target and supported-platform scenarios. The exact refusal in `cli/internal/claudecode/runtime.go:153–156` is carried into the feature; the mutants omit the rejected target or omit Linux from the support statement, independently.
- Request acceptance 2 is addressed by the direct macOS and Linux scenarios. Their exact strings use the same refusal form; each scenario rejects an unknown-target response for its own explicit input.
- The request's test-only scope is addressed by the implementation boundary above, the failure diagnostic from the requested test file, and final-tree review of the diff. The supported platform list and installation are not exercised as new behavior or changed. Nothing is omitted, conflicting, or superseded.

## Tests
- The refusal names both supported platforms and the rejected target: a direct exact-string case in `cli/internal/claudecode/runtime_test.go` (unit)
- Direct calls with supported targets still format the same refusal with the supplied target: two more exact-string cases in the same focused test (unit)

## Feasibility
- The configured Cucumber runner supplies Node and runs from the checkout. The step compiles `./internal/claudecode` from `cli` with the module's Go 1.27.2 toolchain using `go test -trimpath -c`, then runs the resulting native binary from the package directory. The unchanged package passed with native output `PASS`; a scratch overlay adding a failing test emitted `--- FAIL:` and a `runtime_test.go` diagnostic with exit 1. The actual acceptance substitutions change only the named target's return in a temporary overlay, never the source tree. The good observer control reaches the assertion-failure branch; the bad control has a passing package but ignores the rejected target under mutation.
- evidence: {"id":"refusal-observer","kind":"observer","inputs":[".kogen/intents/claude-runtime-unsupported-platform-test/controls.json","cli/internal/claudecode/runtime.go","cli/internal/claudecode/update_test.go","cli/go.mod"],"observers":["features/steps/claude-runtime-unsupported-platform-test__steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/claude-runtime-unsupported-platform-test__steps.js good windows amd64 \"Kogen's Claude Code runtime supports macOS on Apple Silicon and Linux x86-64 only, not windows/amd64\" \"Kogen's Claude Code runtime supports macOS on Apple Silicon and Linux x86-64 only\"","exit":0,"output":"The refusal assertion failed as required.\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/claude-runtime-unsupported-platform-test__steps.js bad windows amd64 \"Kogen's Claude Code runtime supports macOS on Apple Silicon and Linux x86-64 only, not windows/amd64\" \"Kogen's Claude Code runtime supports macOS on Apple Silicon and Linux x86-64 only\"","exit":1,"output":"The package tests passed despite the wrong refusal.\n"}]}
