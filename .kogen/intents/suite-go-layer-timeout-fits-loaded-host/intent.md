# Set a 40-minute limit on the suite go layer

Slug: suite-go-layer-timeout-fits-loaded-host
Model: not applicable — the change edits one constant argument list of a stateless script
Acceptance:
- .kogen/intents/suite-go-layer-timeout-fits-loaded-host/acceptance.feature
- features/steps/suite-go-layer-timeout-fits-loaded-host__steps.js

The go layer of `test/suite.sh` runs `go test -race -count=1 -timeout=40m ./...` in the `cli` directory. Today it passes no `-timeout`, so Go applies its default of 10 minutes per package. The packages `kogen` and `kogen/buildprogram` take 472 to 593 seconds on a quiet host (runs of 16, 17 and 18 Nov 2026), and on a loaded host (load average about 19, release run 20261119T030038Z-2026-11-19-06EAT of 19 Nov 2026) both ran over the limit and Go printed `panic: test timed out after 10m0s` at 600.9 s and 600.7 s, so the release qualification was held although every test passed on its own. An explicit limit of 40 minutes lets a host up to four times slower than a quiet one qualify, while a test that really hangs is still stopped.

Nothing else changes: the same flags in the same order, the working directory `cli`, the log and status handling, and the spec, live-helper and acceptance layers. The only files to change are `test/suite.sh` and `cli/release_test.go`; no documentation, design or README file is touched. No new configuration, environment variable or flag. The existing tests of the release scripts keep passing.

## Decisions
- The go layer entry in `test/suite.sh` becomes `['go', path.join(root, 'cli'), 'go', ['test', '-race', '-count=1', '-timeout=40m', './...']]`: the limit is a fixed constant, with no setting. (evidence: test/suite.sh) (source: request)
- Failure handling stays as it is: the layer exit status is taken from the go process, a nonzero status prints a line starting with `suite: go FAILED` and the suite exits 1. (evidence: test/suite.sh) (source: request)
- A new model-free Go test in `cli/release_test.go`, next to the tests that copy `test/suite.sh` into a scratch project, puts a fake `go` first on PATH that appends its arguments to a file and exits 0, fakes the spec, live-helper and acceptance layers, and never runs the real go test, Cucumber or Quint. (evidence: cli/release_test.go) (source: request)
- Acceptance runs the real `test/suite.sh` from the checkout, copied into a scratch project with an existing archive, matching node dependency stamps and fake layers, through a JavaScript step file, so it does not depend on a test name the Build has to invent. (evidence: test/suite.sh; cli/release_test.go) (source: request)
- Suite log output for a failing layer is `suite: <name> FAILED (<seconds>s)`; the acceptance step only matches the line prefix `suite: go FAILED`. (evidence: test/suite.sh) (source: request)
- Controls patch only `test/suite.sh`; no collection is processed, so no scaling scenario applies. (evidence: test/suite.sh) (assumption: the suite's four-layer list is not a collection of unknown size) (source: request)
- The go layer in test/suite.sh passes the fixed argument -timeout=40m (flags test, -race, -count=1, -timeout=40m, ./...) in the cli directory; no setting, flag or environment variable. (decision: D1, round 1) (constraint: only test/suite.sh and cli/release_test.go change) (constraint: the other three layers and the status handling stay unchanged) (evidence: test/suite.sh; cli/release_test.go) (assumption: A scratch run outside the repository showed the step file passes against the corrected suite and fails against the 20m, project-root and ignored-status variants; it was not Kogen's own readiness run.) (source: request)

## Source comparison
- Explicit `-timeout=40m` with the flags `test`, `-race`, `-count=1`, `./...` in that order, exactly one invocation (request, acceptance 1) — addressed in scenario "The go layer passes an explicit limit of 40 minutes".
- Go layer runs in `cli`, not the project root (request, acceptance 2) — addressed in scenario "The go layer runs in the cli directory".
- Go exit 1 prints a line starting `suite: go FAILED` and the suite exits 1 (request, acceptance 3) — addressed in scenario "A failing go exit status fails the suite".
- Other three layers untouched, no documentation, no new configuration (request constraints) — stated in prose; the diff is limited to `test/suite.sh` and `cli/release_test.go`.
- The focused Go test in `cli/release_test.go` (request, Tests) — addressed in `## Tests`.

## Tests
- The go layer runs `go test -race -count=1 -timeout=40m ./...` exactly once, in the cli directory of the scratch project: a new model-free test in cli/release_test.go with a fake go on PATH and fake spec, live-helper and acceptance layers (integration)
- A failing go exit status prints `suite: go FAILED` and makes the suite exit 1: the same new test in cli/release_test.go with a fake go that exits 1 (integration)
- The scripts of the release keep passing: the existing TestSelfBuildGateRunsTheMaintainedSuiteAndPropagatesItsFailure in cli/release_test.go (existing)
- The whole behavior end to end: the three scenarios of the acceptance feature (scenario)

## Feasibility
- none
