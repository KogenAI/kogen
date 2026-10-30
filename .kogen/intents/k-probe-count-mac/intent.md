# Fix portable probe home emptiness assertion

Slug: k-probe-count-mac
Model: not applicable — this is a test-only formatting correction without meaningful product state
Acceptance:
- .kogen/intents/k-probe-count-mac/acceptance.feature
- features/steps/k_probe_count_mac_steps.js

Correct TestShapeProbeMinimalEnvironmentWiring in cli/shape/shape_test.go so an empty probe home passes on macOS Apple Silicon and Linux x86-64 glibc, while a nonempty home still fails. Replace only the formatting-dependent emptiness check or its count emission; preserve every other assertion. Production code is unchanged. Add no option, limit, timeout or retry.

Prefer checking a clearly delimited count with whitespace-tolerant numeric interpretation in test-only code. Keep the probe's actual ls -A "$HOME" | wc -l observation, including hidden entries. The check must not mistake an unrelated zero elsewhere in the environment for the count. A small test-only predicate shared by the existing assertion and focused regression coverage is permitted; no production abstraction is needed.

Add TestShapeProbeHomeEmptinessRegression in the shape package. Exercise the same emptiness predicate used by the existing test with representative probe output containing a home line followed by the count and LC_ALL=C. Its subtests unpadded-zero, padded-zero, unpadded-one and padded-one respectively accept, accept, reject and reject. Include an unrelated zero line in the nonempty examples so weakening the assertion to finding any zero is rejected. These tests concern the test's observation, not a change to the native probe implementation.

## Decisions
- Empty homes must pass on both supported platforms and nonempty homes must fail; all other assertions remain unchanged. (source: request)
- No production change, new option, limit, timeout or retry. (source: request)

## Source comparison
- Addressed: K-PROBE-COUNT-MAC's failing literal newline-zero-newline check at cli/shape/shape_test.go:1009 is replaced by the portable count check described above and exercised by acceptance and focused regression tests.
- Addressed: supplied BSD count example "       0" versus GNU "0" is retained in the executable Scenario Outline, together with nonempty counterexamples. The supplied Studio Mac evidence (kogen 5d93641, fresh GOCACHE, go test -count=1 ./..., 30 Oct 05:55Z) is historical diagnosis, not a claim of a new Mac run.
- Addressed: the exact requested command go test -count=1 ./shape -run '^TestShapeProbeMinimalEnvironmentWiring$' runs from cli in acceptance. Both supported platform requirements remain in scope; local Linux evidence is not Mac execution proof.
- Omitted: no requested behavior. Superseded: only dependence on wc's left-padding format; no production behavior or other test assertion is superseded.

## Tests
- Empty probe homes pass regardless of BSD/GNU count padding: update TestShapeProbeMinimalEnvironmentWiring and add zero cases in TestShapeProbeHomeEmptinessRegression (regression)
- Nonempty homes still fail the same emptiness predicate, including with unrelated zero output: add one-entry cases in TestShapeProbeHomeEmptinessRegression (regression)
- Other environment, secret exclusion, retained evidence and cleanup assertions remain intact: run TestShapeProbeMinimalEnvironmentWiring unchanged except for its emptiness observation (existing)

## Feasibility
- Focused existing test passes on the current Linux environment: cd cli && go test -count=1 ./shape -run '^TestShapeProbeMinimalEnvironmentWiring$'. (probe 1: exit 0, 27.1 s)
- No external dependency or protocol change; no documentation lookup required. Actual macOS execution remains a supported-platform verification requirement, not an observed result here.
