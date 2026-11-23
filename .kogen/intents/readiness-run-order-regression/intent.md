# Test readiness Run report order

Slug: readiness-run-order-regression
Model: not applicable — the change adds Go tests for a function that examines the environment and keeps no state
Acceptance:
- .kogen/intents/readiness-run-order-regression/acceptance.feature
- features/steps/readiness-run-order-regression__steps.js

This change only adds direct tests of the public `Run` function to `cli/readiness/readiness_test.go`. `Run` returns the checks install, git, config and models in that order. For a configured project inside a Git checkout it runs the config and models checks against the repository root, even when the project directory is nested. For a project outside a Git checkout it still returns all four checks in that order: the git check fails, and config and models are computed from the project directory. Nothing is replaced or removed. `cli/readiness/readiness.go`, the individual check helpers and all other production code are not touched.

## Decisions
- The change touches `cli/readiness/readiness_test.go` only; `cli/readiness/readiness.go` and every other production file stay unchanged. (constraint: no other tracked file changes besides the Intent files) (evidence: cli/readiness/readiness.go; cli/readiness/readiness_test.go) (source: request)
- The new tests are acceptance-checked by behaviour, not by name: the acceptance runs the package tests against `Run` variants injected with `go test -overlay` (install last, config before git, the nested working directory checked instead of the repository root, an early return after the Git failure, the parent of a non-Git project checked) and requires the package tests to fail, so the Build is free to name its tests. (constraint: acceptance names no test the Build has to invent) (evidence: cli/readiness/readiness.go; cli/readiness/readiness_test.go) (assumption: a scratch run in a copy showed the tests below pass on the unchanged Run and are rejected by each variant; the test layout is the Build's choice) (source: request)
- Run's report order is install, git, config, models, with exactly four checks, whether or not the project is inside a Git checkout. (evidence: cli/readiness/readiness.go) (source: request)

## Source comparison
- Request scenario 1, a configured project inside a Git checkout returns the four checks in order and checks the repository root: addressed by the scenario "A configured project inside a Git checkout reports in order and checks the repository root".
- Request scenario 2, a project outside a Git checkout still returns all four checks with the git failure and independently computed config and models: addressed by the scenario "A project outside a Git checkout still reports all four checks".
- Request scope, `cli/readiness/readiness_test.go` only, readiness behavior and helpers out of scope: addressed by the first Decision; the final-tree review checks it, no acceptance scenario does.

## Tests
- Run returns install, git, config, models in that order and checks the repository root for a nested project inside a Git checkout: a new Go test in `cli/readiness/readiness_test.go` (unit)
- Run returns all four checks in order, with the git failure and config and models computed from the project directory, outside a Git checkout: a new Go test in `cli/readiness/readiness_test.go` (unit)

## Feasibility
- none
