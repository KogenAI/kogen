# Drop kogen's executor and loop wire tests

Slug: k-drop-kogen-wire-goldens
Model: not applicable — deleting test files that pin other repositories' wire behaviour adds no state
Acceptance:
- .kogen/intents/k-drop-kogen-wire-goldens/acceptance.feature
- features/steps/k-drop-kogen-wire-goldens__cli.js

Request K-DROP-KOGEN-WIRE-GOLDENS (entanglement audit finding F13, change_type refactor). kogen stops testing kogen-executor and kogen-loop wire behaviour, because the owning repositories now pin it in their own contract suites (K-EXEC-CONTRACT-WIRE-GOLDENS, L-CONTRACT-WIRE-GOLDENS).

Delete these files completely: `cli/research_removal_test.go` (TestResearchRemovalDefaults and its helpers knobFixtureRaw, knobFixtureInput, knobServer, newKnobServer, knobSession), `cli/response_budget_test.go` (TestShapeBudgetRoleContract) and `cli/compatible_login_test.go` (TestCompatibleLoginUserOrigin, TestCompatibleLoginRoleOrigins, TestCompatibleLoginLegacyOriginHint, TestCompatibleLoginContractText and their helpers compatibleWorld, loginCLI, savedCompatible, recordingTransport, respondAt, originKeyFixture, conflictingRepo). Nothing else in package `main` (`cli/`) uses those helpers. `runCaptured` is defined in `cli/run_test.go` and stays. The golden `cli/testdata/loop_knobs_golden.json` was already deleted by commit 96b7438, so it must stay absent and must not be recreated.

Keep every check that runs the installed kogen binary from outside, unchanged. In `cli/` these are TestInstalledKeyLoginUnderPipesAndATerminal (`cli/login_installed_test.go`), TestUsageLimitResumeInstalledRound2/3 and TestUsageLimitPackagingIsolationRound2/3 (`cli/usage_limit_installed_test.go`), TestInstalledBinaryAnswersTheHookBeforeAnyOtherStartup, TestInstalledProbeDeadline and TestObservationRejectsAnInstalledReleaseWithoutItsProgram. In the specification, these are the installed-CLI scenarios in `spec/features/08-chatgpt.feature`, "The compatible login reads the base URL, then the key, and binds the key to that origin" and "The compatible login refuses an HTTP base URL and keeps a keyless localhost host login-free". All other tests stay unchanged too.

No behaviour change: no production Go code, documentation, specification or configuration changes. `cli/go.mod` and `cli/go.sum` are protected and stay byte-identical: do not run `go mod tidy` and do not edit requirements, even if a module becomes used only outside tests. Do not edit `cli/third_party/kogen-loop/**`, `cli/loop-pin.json` or `.kogen/project.yaml`. No timeout or other limit is raised. Leave historical records alone, including other Intents' files and step files that name the removed tests, `docs/evidence/k-pin-knobs/README.md` and `test/checktime-clock.md`. Their `budgetClock` row describes an older `cli/build` audit. These are not active checks.

## Decisions
- Delete the three test files whole, not only some of their subtests. The only checks kept are those that run the installed kogen binary from outside; the in-process `run(...)` CLI and help/docs checks in compatible_login_test.go go with the file (source: request)
- No behaviour change, protected cli/go.mod and cli/go.sum unchanged, no timeout raised (source: request)

## Source comparison
- addressed: Problem and Need 1 (remove cli/research_removal_test.go, cli/response_budget_test.go, cli/compatible_login_test.go and cli/testdata/loop_knobs_golden.json). Acceptance scenario "Remove the executor and loop wire tests from kogen" checks that all four paths are absent, and scenario "The cli package lists no wire tests and keeps its installed-binary checks" checks that `go test -list` no longer names the six removed tests.
- addressed: Need 1 "keeping any check that runs the installed kogen binary from outside". The listing scenario requires the seven installed-binary Go tests named above, and the removal scenario requires both installed-CLI compatible-login scenarios in spec/features/08-chatgpt.feature.
- addressed: Need 2 "No behaviour change": the list of what stays unchanged above, plus the configured compile, go-test, spec and cucumber checks.
- addressed: Constraints "cli/go.mod and go.sum are protected; no timeout raised". Both files are protected and must not be edited, and no existing timeout changes.
- conflicting/superseded: the golden cli/testdata/loop_knobs_golden.json is already absent at HEAD (deleted in 96b7438 by k-fullscan-assembly). Its removal is already done, and it only has to stay absent.
- omitted: the dependencies K-EXEC-CONTRACT-WIRE-GOLDENS and L-CONTRACT-WIRE-GOLDENS are other repositories' suites. This Intent neither checks nor changes them.

## Tests
- The wire tests and golden are gone from kogen: delete the three files. The acceptance scenario checks that all four paths are absent (regression)
- The remaining cli package tests still compile and none of the six removed tests is listed: acceptance runs `go test -list '.*' .` in cli and checks the listing (integration)
- Installed-binary checks are kept: acceptance requires the seven installed-binary test names in the listing and both 08-chatgpt.feature compatible-login scenarios (existing)
- No behaviour change: the configured compile, go-test, spec and cucumber checks pass unchanged (existing)

## Feasibility
- `go test -list '.*' .` in cli on the unchanged tree exited 0, printed one test name per line, including the six tests to remove and the seven installed-binary tests, and ended with `ok  \tkogen\t0.631s` (about 2.4 s warm). This is local command observation used to shape the listing step, not proof of the feature.
