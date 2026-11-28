# Test bounded stderr persistence accounting

Slug: bounded-stderr-persistence-tests
Model: not applicable — this adds unit tests of an existing writer's byte accounting, not new state or transitions
Acceptance:
- .kogen/intents/bounded-stderr-persistence-tests/acceptance.feature
- features/steps/bounded-stderr-persistence-tests__steps.js

Add direct unit tests in the new file `cli/internal/claudecode/persistence_test.go` for `stderrPersistence.Write` in `cli/internal/claudecode/persistence.go`. `persistence.go` is in scope as the interface under test and needs no edit. Keep all existing tests. Nothing is replaced or removed. Do not change persistence limits, stream handling or event fields.

## Decisions
- The tests construct `stderrPersistence{w: <writer>, cap: <small cap>}` directly in package `claudecode` and call `Write`, comparing the returned count and error, the bytes that reached the underlying writer, and the `kept` and `lost` fields. (evidence: cli/internal/claudecode/persistence.go; cli/internal/claudecode/session.go) (source: request)
- A write that crosses the cap returns the full input length with a nil error, the underlying writer receives exactly the prefix that fits within the cap (never more than the cap in total), and `lost` grows by every byte not retained. Cover a single write larger than the cap and a second write that crosses the cap after an earlier write was fully retained. (decision: D2, round 1) (evidence: cli/internal/claudecode/persistence.go) (source: request)
- A short underlying write (the writer accepts fewer bytes than offered, with or without returning an error) leaves `Write` returning the full input length with a nil error, counts only the bytes actually written in `kept`, and adds the unwritten portion to `lost`. Cover both a short count with a nil error and a short count with `io.ErrShortWrite`. (decision: D3, round 1) (evidence: cli/internal/claudecode/persistence.go) (source: request)
- After the cap is exhausted exactly, each later write returns its full length with a nil error, adds its full length to `lost`, does not increase `kept` and reaches the underlying writer with no bytes. Use more than one later write so accounting across calls is checked. (decision: D4, round 1) (evidence: cli/internal/claudecode/persistence.go) (source: request)
- Verify test strength using the real package test binary and temporary mutants of `persistence.go`, with no preselected new test names; each mutant must be rejected by an assertion in persistence_test.go, not by a build failure or panic. (decision: D5, round 1) (constraint: Require a failing assertion in persistence_test.go, not a build failure or panic.) (evidence: cli/internal/claudecode/persistence.go; .kogen/project.yaml; cli/go.mod) (source: request)
- Shaper choice for acceptance harness safety only: bound the initial Go build at 85000 ms, each warmed mutation build at 12000 ms and each test binary run at 5000 ms, within Cucumber step timeouts of 95000 ms and 110000 ms. These are harness deadlines, not product requirements. (decision: D6, round 1) (evidence: .kogen/project.yaml) (assumption: Neither the request nor the configuration establishes these deadline values.) (source: request)
- Add direct unit tests of stderrPersistence.Write in a new cli/internal/claudecode/persistence_test.go covering cap crossing, short underlying writes and writes after the cap is exhausted; verify strength with temporary mutants of persistence.go. (decision: D1, round 1) (constraint: No change to persistence limits, stream handling or event fields) (constraint: Each mutant must be rejected by an assertion in persistence_test.go) (evidence: cli/internal/claudecode/persistence.go; cli/internal/claudecode/session.go; .kogen/project.yaml; cli/go.mod) (assumption: Harness deadlines (85000/12000/5000 ms) are shaper choices; scratch-copy runs of the good and bad observer controls passed on this machine, but the checkout itself was not modified.) (source: request)

## Source comparison
- Addressed: `ev-f48adbbc` identifies the gap: `stderrPersistence.Write` has no direct tests in `cli/internal/claudecode`. The outcome and Tests below add coverage only. (evidence: cli/internal/claudecode/persistence.go)
- Addressed: request acceptance 1 maps to **Count the overflow of writes that cross the cap**; the acceptance rejects tests that check only retained output and would miss wrong loss accounting or a short return count.
- Addressed: request acceptance 2 maps to **Count the unwritten portion of a short write**; the acceptance rejects tests that use only a fully successful writer.
- Addressed: request acceptance 3 maps to **Count writes after the cap is exhausted**; the acceptance rejects tests that check only the first write.
- Out of scope and preserved: persistence limits, stream handling and event fields are not changed or tested.

## Tests
- Writes crossing the cap return the full length with no error, retain at most the cap and count every unretained byte in lost: seed a capped writer, write once beyond the cap and write again across the cap, then compare return values, retained bytes, kept and lost (unit)
- A short underlying write counts the unwritten portion as lost while Write accepts the full input: use a writer that accepts fewer bytes than offered, with and without an error, and compare return values, retained bytes, kept and lost (unit)
- Later writes after the cap is exhausted add their full length to lost without increasing kept: exhaust the cap, write twice more and compare return values, retained bytes, kept and lost (unit)

## Feasibility
- The configured Cucumber runner supplies Node and runs from the repository root. The observer compiles `./internal/claudecode` from `cli` with `go test -trimpath -c -o <temporary binary>` and an optional Go overlay, then runs the native binary from the package directory. Mutants of `persistence.go` and weakened test bodies are confined to temporary overlays. In an external scratch copy, the good control passed and caught all ten mutants and the bad control left each category's mutants alive.
- evidence: {"id":"stderr-persistence-observer","kind":"observer","inputs":[".kogen/intents/bounded-stderr-persistence-tests/controls.json","cli/internal/claudecode/persistence.go","cli/go.mod"],"observers":["features/steps/bounded-stderr-persistence-tests__steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/bounded-stderr-persistence-tests__steps.js good","exit":0,"output":"Stderr persistence tests caught every mutation.\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/bounded-stderr-persistence-tests__steps.js bad","exit":1,"output":"Incomplete stderr persistence tests let the corresponding mutations survive.\n"}]}
