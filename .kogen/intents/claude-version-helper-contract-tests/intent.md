# Test Claude Code version helpers

Slug: claude-version-helper-contract-tests
Model: not applicable — these direct string and boolean results have no state transitions
Acceptance:
- .kogen/intents/claude-version-helper-contract-tests/acceptance.feature
- features/steps/claude-version-helper-contract-tests__steps.js

Add direct Go regression tests only in `cli/internal/claudecode/runtime_test.go`. Keep the existing tests. Do not change `Version`, implementation code, or runtime selection policy; nothing is replaced or removed.

## Decisions
- Cover `FirstField(answer string) string`, `Pinned(answer string) bool`, and `NotPinnedMessage(path, answer, want string) string` in the local `claudecode` package. (evidence: cli/internal/claudecode/runtime.go; cli/internal/claudecode/runtime_test.go) (source: request)
- The mismatch diagnostic names the runtime path, the reported answer, and the pinned or active expected version. The expected version is pinned when `want == Version` and active otherwise. (evidence: cli/internal/claudecode/runtime.go) (source: request)

## Source comparison
- Evidence `ev-45648617` and the expected direct regression coverage are addressed by the three callable interfaces and the Tests below. The similarly named tests in `cli/consumes/kogen-executor/runtime_test.go` import the executor dependency rather than the local package and stay unchanged. (evidence: cli/internal/claudecode/runtime.go; cli/internal/claudecode/runtime_test.go; cli/consumes/kogen-executor/runtime_test.go)
- Request acceptance 1 is addressed by **Read just the first version field**: empty and whitespace-only output return an empty string; leading whitespace and trailing metadata leave just the first field. That row rejects trimming the entire answer without dropping metadata.
- Request acceptance 2 is addressed by **Match the entire pinned version field**: the pin in the first field is accepted; empty output, a distinct numeric version containing the pin, and a version with an attached suffix are rejected. The last two rows exercise substring matching independently.
- Request acceptance 3 is addressed by **Name the path, answer and expected runtime version**: both formats name the runtime path and full reported answer and identify the expected version as pinned or active with its corresponding value. The active case rejects using the pinned label for the same active expected version. Separate rows also reject omitting the path or replacing the reported answer.
- The scope and exclusions are addressed by the opening boundary and coverage-only fixtures. There are no omitted, conflicting or superseded requirements. The feature rows supply concrete regression examples, not additional product inputs or rules.

## Tests
- Empty and whitespace-only output return the empty string; output with leading whitespace and trailing metadata returns just its first whitespace-separated field: direct `FirstField` assertions on the returned string (unit)
- Only an exact pinned first field matches; empty, different-version and attached-suffix output do not: direct `Pinned` assertions on the returned boolean (unit)
- The mismatch message includes the supplied path, reported answer and pinned or active expected version: direct `NotPinnedMessage` assertions on the returned message for both branches (unit)

## Feasibility
- The configured acceptance runner supplies Node and Cucumber. From `cli`, the observer uses Go 1.27.2 to compile with `go test -trimpath -c -o <temporary binary> ./internal/claudecode`, with a temporary overlay for mutants. It runs the binary from `cli/internal/claudecode`. The unchanged package emitted `PASS` and exited 0 (probe 1: exit 0, 8.4 s). Mutations exercise the concrete examples in the feature. A compiler error is not evidence of a failed assertion. (evidence: .kogen/project.yaml; cli/go.mod)
- The scratch proof fixtures preserve the unsupported-platform test and add focused assertions; wrong controls remove or weaken those assertions independently. The generated control bodies were formatted with `gofmt`. (probe 2: exit 0, 0.1 s)
- The observer accepted the real run of the good fixture and rejected the real passing run of the fixture without the metadata assertion. The command checked both exit statuses. (probe 3: exit 0, 4.3 s)
- evidence: {"id":"version-regression-observer","kind":"observer","inputs":[".kogen/intents/claude-version-helper-contract-tests/controls.json","cli/internal/claudecode/runtime.go","cli/internal/claudecode/update_test.go","cli/go.mod"],"observers":["features/steps/claude-version-helper-contract-tests__steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/claude-version-helper-contract-tests__steps.js good","exit":0,"output":"The test caught the wrong version result.\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/claude-version-helper-contract-tests__steps.js bad","exit":1,"output":"The tests passed despite the wrong version result.\n"}]}
