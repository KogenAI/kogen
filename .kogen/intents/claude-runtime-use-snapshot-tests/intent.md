# Test Claude Code role-start history snapshots

Slug: claude-runtime-use-snapshot-tests
Model: not applicable — this adds unit tests of an existing snapshot contract, not new state or transitions
Acceptance:
- .kogen/intents/claude-runtime-use-snapshot-tests/acceptance.feature
- features/steps/claude-runtime-use-snapshot-tests__steps.js

Add direct contract coverage in `cli/internal/claudecode/update_test.go`. `cli/internal/claudecode/update.go` is in scope as the interface under test; it needs no edit. Keep all existing tests. Nothing is replaced or removed. Do not change runtime selection, recorded fields, or the lifetime of process-local history.

## Decisions
- The tests arrange two recorded role starts in isolated test history and assert through `Uses() []RuntimeUse`. (evidence: cli/internal/claudecode/update.go; cli/internal/claudecode/update_test.go) (source: request)
- After recording two role starts, `Uses` returns both entries in recording order with their role, version, source, and path. Compare the complete slice with the expected records; the version is the first field of the supplied runtime answer and the source is `pinned` or `updated`. (evidence: cli/internal/claudecode/update.go; cli/internal/claudecode/runtime.go) (source: request)
- Mutating an entry in a returned slice does not change the next `Uses` result. Appending to a returned slice does not add a recorded role start. Compare fresh reads to the unmodified history, using an independent expectation rather than the slice being edited; do not assert slice capacity. (evidence: cli/internal/claudecode/update.go) (source: request)
- Verify test strength using the real package test binary and temporary Uses mutants, with no preselected new test names. (decision: D1, round 1) (constraint: Require a failing assertion in update_test.go, not a build failure or panic.) (evidence: cli/internal/claudecode/update.go; cli/internal/claudecode/update_test.go; .kogen/project.yaml; cli/go.mod) (source: request)
- Shaper choice for acceptance harness safety only: bound the initial Go build at 85000 ms, each warmed mutation build at 12000 ms and each test binary run at 5000 ms, within Cucumber step timeouts of 95000 ms for the background and 110000 ms for a mutation group. These are harness deadlines, not runtime requirements or assertions about product speed. (evidence: .kogen/project.yaml) (assumption: Neither the request nor the cited configuration establishes these deadline values, and no assumption records them.) (source: request)

## Source comparison
- Addressed: `ev-6bb58b16` identifies the coverage gap: `update.go` documents ordered role starts and already returns a copy, while `update_test.go` tests Active and version comparisons but not Uses. The outcome and Tests below add coverage rather than changing behavior. (evidence: cli/internal/claudecode/update.go; cli/internal/claudecode/update_test.go)
- Addressed: request acceptance 1 maps to **Test complete ordered role-start history**. The full two-entry comparison must reject latest-only, reversed order, and independently dropping role, version, source, or path.
- Addressed: request acceptance 2 maps to **Test that overwrites do not change recorded history**. Replacing an entry must leave the next read intact; returning the internal slice directly must fail this test.
- Addressed: request acceptance 3 maps to **Test that appends do not add a recorded start**. The next read must equal the original history, with no caller-added entry. In Go, a caller's append alone does not extend the recorder's slice header; the append mutant exposes a shared snapshot buffer and incorrectly includes the caller-written tail on the next read. It restores the prefix before reading so the overwrite assertion cannot mask the missing append assertion.
- Addressed: the source scope and exclusions are preserved by the test-only outcome; acceptance mutants exist only in scratch overlays. No requested behaviors are omitted, conflicting, or superseded.

## Tests
- Two recorded role starts are exposed with all fields in recording order: seed distinct starts and compare the result of `Uses()` to both complete expected records in order (unit)
- Caller overwrite cannot alter the recorded role starts: replace an entry in a returned slice and compare a fresh `Uses()` to the untouched expected history (unit)
- Caller append cannot add a recorded role start: append a distinct entry to a returned slice and compare a fresh `Uses()` to the untouched expected history, including its length (unit)

## Feasibility
- The configured Cucumber runner supplies Node and runs from the repository root. The observer compiles `./internal/claudecode` from `cli` with the module's Go 1.27.2 toolchain using `go test -trimpath -c -o <temporary binary>` and an optional Go overlay. It runs the native binary from the package directory. The unchanged package emitted `PASS` and exited 0 (probe 1: exit 0, 0.4 s). The shape controls replace only the test file; the observer's production mutants are confined to temporary overlays of `update.go`. (evidence: .kogen/project.yaml; cli/go.mod)
- The scratch generation kept existing tests and formatted the good and three independently weakened test overlays with `gofmt` (probe 2: exit 0, 0.1 s). The final observer found every mutant rejected by the complete tests (probe 3: exit 0, 5.8 s) and each mutant survived when its corresponding assertion alone was omitted (probe 4: exit 1, 6.0 s).
- evidence: {"id":"uses-snapshot-observer","kind":"observer","inputs":[".kogen/intents/claude-runtime-use-snapshot-tests/controls.json","cli/internal/claudecode/update.go","cli/internal/claudecode/update_test.go","cli/go.mod"],"observers":["features/steps/claude-runtime-use-snapshot-tests__steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/claude-runtime-use-snapshot-tests__steps.js good","exit":0,"output":"Uses assertions caught every mutation.\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/claude-runtime-use-snapshot-tests__steps.js bad","exit":1,"output":"Incomplete Uses tests let the corresponding mutations survive.\n"}]}
