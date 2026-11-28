# Test harness loading of missing and malformed

Slug: malformed-harness-read-tests
Model: not applicable — this adds unit tests of an existing file reader, not new state or transitions
Acceptance:
- .kogen/intents/malformed-harness-read-tests/acceptance.feature
- features/steps/malformed-harness-read-tests__steps.js

Add direct regression tests to the existing `cli/internal/claudecode/update_test.go` for `readHarness` in `cli/internal/claudecode/update.go`. `update.go` is the interface under test and needs no edit. Keep all existing tests. Nothing is replaced or removed. Do not change the harness format or update scheduling.

## Decisions
- The tests call `readHarness(root)` directly in package `claudecode` with a temporary folder as root and compare the returned `Harness` with `reflect.DeepEqual`. (evidence: cli/internal/claudecode/update.go; cli/internal/claudecode/update_test.go) (source: request)
- A missing harness file returns an empty Harness (`Harness{}`) and the read changes nothing on the filesystem: an existing empty root folder still has no entries, and a root folder that does not exist still does not exist afterwards. `readHarness` has no error result, so there is no error to check. (decision: D2, round 1) (evidence: cli/internal/claudecode/update.go) (source: request)
- A malformed JSON harness returns an empty Harness, never partially used state. Cover text that is not JSON, truncated JSON, and syntactically valid JSON with a wrong-typed value after fields that decode (`checked_at`, `last_result` and part of `failed` are decoded before the type error, so a reader that keeps what decoded would leak them). (decision: D3, round 1) (evidence: cli/internal/claudecode/update.go) (source: request)
- A valid harness file returns a Harness whose checked time, last result and failed-version map entries (each version with its failing check) are all preserved. (decision: D4, round 1) (evidence: cli/internal/claudecode/update.go) (source: request)
- Verify test strength using the real package test binary and temporary mutants of `update.go`, with no preselected new test names; each mutant must be rejected by an assertion in update_test.go, not by a build failure or panic. (decision: D5, round 1) (constraint: Require a failing assertion in update_test.go, not a build failure or panic.) (evidence: cli/internal/claudecode/update.go; .kogen/project.yaml; cli/go.mod) (source: request)
- Shaper choice for acceptance harness safety only: bound the initial Go build at 85000 ms, each warmed mutation build at 12000 ms and each test binary run at 5000 ms, within Cucumber step timeouts of 95000 ms and 110000 ms. These are harness deadlines, not product requirements. (decision: D6, round 1) (evidence: .kogen/project.yaml) (assumption: Neither the request nor the configuration establishes these deadline values.) (source: request)
- Add direct tests of readHarness for missing, malformed and valid harness files in update_test.go; verify strength with temporary mutants of update.go. (constraint: No change to the harness format or update scheduling) (constraint: Each mutant must be rejected by an assertion in update_test.go) (evidence: cli/internal/claudecode/update.go; cli/internal/claudecode/update_test.go; .kogen/project.yaml; cli/go.mod) (assumption: Harness deadlines (85000/12000/5000 ms) are shaper choices; scratch-copy runs of the good and bad observer controls passed on this machine, but the checkout itself was not modified.) (source: request)
- Add direct tests of readHarness for missing, malformed and valid harness files in update_test.go; verify strength with temporary mutants of update.go via an observer step. (decision: D1, round 1) (constraint: No change to harness format or update scheduling) (constraint: Each mutant must be rejected by an assertion in update_test.go) (evidence: cli/internal/claudecode/update.go; cli/internal/claudecode/update_test.go; .kogen/project.yaml; cli/go.mod) (assumption: Harness deadlines (85000/12000/5000 ms) are shaper choices; scratch-copy runs of good and bad controls passed but the checkout was not modified.) (source: request)

## Source comparison
- Addressed: `ev-c5f422b9` identifies the gap: `readHarness` has no direct coverage in `update_test.go`, which tests only `Harness.due`. The outcome and Tests below add coverage only. (evidence: cli/internal/claudecode/update.go; cli/internal/claudecode/update_test.go)
- Addressed: request acceptance 1 maps to **Count a missing harness as empty without changes**; the acceptance rejects tests that use only a present file.
- Addressed: request acceptance 2 maps to **Discard a malformed harness entirely**; the acceptance rejects tests that check only that loading does not panic, and implementations that let decoded fields leak through.
- Addressed: request acceptance 3 maps to **Keep the history of a valid harness**; the acceptance rejects tests that cover only failure recovery.
- Out of scope and preserved: the harness format and update scheduling are not changed.

## Tests
- A missing harness file loads as an empty Harness and changes nothing on the filesystem: read a root with no harness file and a root that does not exist, then compare the result and the folder state (unit)
- A malformed JSON harness loads as an empty Harness with no decoded field kept: write non-JSON, truncated JSON and wrong-typed JSON that decodes some fields first, then compare the result (unit)
- A valid harness file keeps its checked time, last result and failed versions: write a full record and compare the whole Harness (unit)

## Feasibility
- The configured Cucumber runner supplies Node and runs from the repository root. The observer compiles `./internal/claudecode` from `cli` with `go test -trimpath -c -o <temporary binary>` and an optional Go overlay, then runs the native binary from the package directory. Mutants of `update.go` and weakened test bodies are confined to temporary overlays. In an external scratch copy, the good control passed and caught all nine mutants and the bad control left each category's mutants alive.
- evidence: {"id":"harness-read-observer","kind":"observer","inputs":[".kogen/intents/malformed-harness-read-tests/controls.json","cli/internal/claudecode/update.go","cli/go.mod"],"observers":["features/steps/malformed-harness-read-tests__steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/malformed-harness-read-tests__steps.js good","exit":0,"output":"Harness read tests caught every mutation.\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/malformed-harness-read-tests__steps.js bad","exit":1,"output":"Incomplete harness read tests let the corresponding mutations survive.\n"}]}
