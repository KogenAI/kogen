# Resolve an absolute Node for shape tests

Slug: k20b-test-node
Model: not applicable — test-fixture environment change, no meaningful state
Acceptance:
- .kogen/intents/k20b-test-node/acceptance.feature
- features/steps/k20b_test_node_steps.js

The `cli/shape` tests currently let the step self-check find `node` through PATH. On hosts where `node` is a version-manager shim (mise) that only works under the developer's HOME, the shape fixtures (which set their own HOME) break, e.g. `TestShapeDoesNotLetAnUntrustedDocumentDirectTheDecisions`.

Change only test code in `cli/shape` (no production behaviour change): `TestMain` in `cli/shape/main_test.go` resolves one absolute Node binary once, with the developer's own HOME and before any fixture changes HOME, and exports it as `KOGEN_NODE` in the test process environment so every fixture (whose Env is copied from the process environment, and whose step self-check falls back to `KOGEN_NODE`) uses it. Resolution order: `KOGEN_NODE` when set and an executable regular file; else the output of `node -p process.execPath` run (with the current environment/HOME) on the `node` found on PATH; else the package fails in TestMain with a clear message on stderr naming the missing Node (exit 1, no skipping). Likewise `KOGEN_CUCUMBER`: when set keep it; otherwise, when `test/acceptance/node_modules` exists in the repository, set it to that absolute directory. `realQuintTools` in `contract_test.go` uses the same resolved Node (`KOGEN_NODE`) instead of `exec.LookPath("node")`/`mise which`. Existing tests with fake node programs (init_test.go) stay as they are.

## Decisions
- Node is resolved once per package in TestMain and passed as KOGEN_NODE (source: request)
- Cucumber is resolved the same way as KOGEN_CUCUMBER where fixtures need it (source: request)
- A missing Node fails the package with a message naming Node rather than skipping (source: request)
- No production code changes (source: request)

## Source comparison
- Absolute Node via KOGEN_NODE, else resolved execPath with developer HOME, else clear failure: addressed in main_test.go TestMain (request item 1).
- KOGEN_CUCUMBER: addressed (request item 2).
- No production behaviour change: addressed; only _test.go files change.
- Shim acceptance (fake `node` failing when HOME differs, first on PATH, `go test ./shape` passes): addressed by acceptance scenario running the previously failing test under such a shim. The scenario runs the K20 untrusted-document test, not the whole package, to bound time; the whole package runs in the configured go-test check.
- All configured checks pass: addressed by normal verification.

## Tests
- Shape fixtures use an absolute real Node even when PATH `node` is a HOME-dependent shim: run `go test ./shape -run TestShapeDoesNotLetAnUntrustedDocumentDirectTheDecisions` with such a shim first on PATH and KOGEN_NODE unset (scenario)

## Feasibility
- none
