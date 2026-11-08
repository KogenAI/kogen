# Qualify the fixed component pins

Slug: k-integrate-pins-20261108t025831z
Model: not applicable — repair synthetic test files, without changing product state
Acceptance:
- .kogen/intents/k-integrate-pins-20261108t025831z/acceptance.feature
- features/steps/k-integrate-pins-20261108t025831z__qualification.js

Make full qualification green on pin commit cd49887c80cf51d8f761e92024d5d255333aab26. The executor transition is 5e9ca167fa44 -> 12bb6262e745. Every component pin is fixed, including kogen-shaping's current pin. Change kogen tests to follow the executor's new contract; do not change the executor, pin files or production validation.

The implementation MUST CHANGE cli/consumes/kogen-executor/helper_test.go: fakeRuntime currently writes an undersized executable. It is not code this contract keeps unchanged. Keep TestProbeRunsTheInstalledRuntime's assertions in cli/consumes/kogen-executor/runtime_test.go, but change its fixture writer to sparse-truncate after writing the shell script. Likewise CHANGE cli/usage_limit_installed_test.go's installed shim writer to sparse-truncate after the script. Preserve executable mode, check errors, and ensure scripts terminate or exec before trailing padding; an exec failure must exit rather than parse padding. No large in-memory padding buffer, no runtime download and no validation bypass.

Keep all five reported regressions and their useful assertions: TestProbeRunsTheInstalledRuntime, TestUsageLimitPackagingIsolationRound2, TestUsageLimitPackagingIsolationRound3, TestUsageLimitResumeInstalledRound2 and TestUsageLimitResumeInstalledRound3. Fix every failure's cause. Do not skip tests, raise timeouts or move pins. Limit implementation edits to kogen tests, including consumes/component contract tests.

Delivery requires the complete qualification, not merely this Intent's focused regression. Run `(cd cli && gofmt -l .)` and require empty output; run `(cd cli && go build ./... && go vet ./... && GOFLAGS=-trimpath go test ./...)`, `(cd spec && sh check.sh)`, `sh packaging/package.sh`, and `sh test/suite.sh` successfully. Keep configured checks unchanged. The complete suite, not just chapter 04, is required for installed-release acceptance. Packaging isolation and installed resume coverage must remain meaningful. No live account calls are needed for synthetic test repairs.

## Decisions
- Keep the fixed tuple, including executor 12bb6262e745 and shaping cb9498a719ef. (evidence: cli/go.mod) (source: request)
- Change fakeRuntime at its actual writer in helper_test.go; retain the Probe expectations. (evidence: cli/consumes/kogen-executor/helper_test.go; cli/consumes/kogen-executor/runtime_test.go) (source: request)
- Repair the installed shim while preserving round-two and round-three stop/resume and packaging-isolation tests. (evidence: cli/usage_limit_installed_test.go) (source: request)
- Size each stub to the executor platform pin using sparse truncation after the script, with no bypass. (source: request)

## Source comparison
- addressed: request base cd49887c80cf and transition 5e9ca167fa44 -> 12bb6262e745 map to the fixed-tuple requirement above; all other pins, especially shaping, remain fixed.
- addressed: supplied reproducer's 229-519 byte stand-ins at .kogen/claude-code/2.1.318/claude and expected 319598464-byte runtime map to acceptance.feature and the two explicitly changeable fixture writers. The executor's platform pin must be used, not one platform's size on all hosts.
- addressed: all five named failures and full gofmt/build/vet/Go/spec/acceptance/packaging qualification remain required. Focused scenario acceptance does not replace the complete mandatory delivery commands.
- addressed: diagnostic proposal to fix tests only with sparse truncate is adopted after inspecting both writers and local pinned executor code. Runtime validation stays unchanged, but the undersized test fixture implementation is replaced.
- omitted: historical temporary paths, Build IDs, durations and unrelated help output are diagnostic evidence, not new product output requirements. No product feature, bypass, pin change or live probing is added.

## Tests
- Managed runtime fixtures follow the executor contract without changing Probe expectations: execute the existing consumed executor contract package in acceptance (regression)
- Installed stops and fresh resumes preserve completed work and evidence in rounds two and three: retain and pass TestUsageLimitResumeInstalledRound2 and TestUsageLimitResumeInstalledRound3 (existing)
- Packaging carries current source without mutating the checkout: retain and pass TestUsageLimitPackagingIsolationRound2 and TestUsageLimitPackagingIsolationRound3 (existing)
- Full qualification is green without weakened checks: run the complete mandatory delivery commands above (integration)

## Feasibility
- Probe 1 inspected the local pinned executor size table and stand-in approach; an existing TestRuntimeLayout verbose run passed (exit 0).
- Probe 2 confirmed both local platform sizes and listed all five existing regression tests (exit 0).
- Probe 3 could not read privately retained proposals from the scratch copy (ENOENT); the unchanged consumed package still reproduced the size rejection (exit 1). This is not successful control evidence.
- Probe 4 changed only fakeRuntime in a scratch copy to sparse-truncate its executable to the observed host pin and ran `cd cli && go test -count=1 ./consumes/kogen-executor`: exit 0, output `ok  kogen/consumes/kogen-executor` with timing. This establishes that the retained Probe assertions can pass with the requested fixture repair, without production edits. It is not full qualification or proof of the installed usage-limit repair.
- Readiness's baseline failure at runtime_test.go:85 is the requested missing repair: the unchanged 229-byte fakeRuntime is rejected against the 319598464-byte pin. There are no skipped scenario tails in this single-step scenario. No full qualification success is claimed during shaping.
