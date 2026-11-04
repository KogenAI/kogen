# Make adoption tests follow component pins

Slug: k-adoption-tests-follow-pins
Model: not applicable — this changes test expectations, not a state machine
Acceptance:
- .kogen/intents/k-adoption-tests-follow-pins/acceptance.feature
- features/steps/k-adoption-tests-follow-pins__checks.js

Update cli/assembly_test.go and cli/research_removal_test.go so adoption does not require editing release-specific expected versions or copying the loop's output-cut implementation. Keep testing the actual packaged executable, not the Go test executable. Do not change runtime behavior, dependency pins, vendored files, packaging behavior or configured checks. Acceptance changes pins and packaging only in disposable copies.

## Decisions
- TestAssemblyUsesThePinnedComponents must derive the expected versions of all seven Kogen component modules from the require declarations in cli/go.mod. Keep the explicit seven component identities, but remove their hard-coded versions. Missing required components, differing binary versions and replacements must fail. Reject replacements of these components in the manifest as well as in executable build information. The intentional kogen-loop local replacement is outside this seven-component assertion. (source: request)
- Continue building and inspecting the release archive using testrelease.Package and debug/buildinfo. Read the source manifest rather than substituting resolved module versions from the binary. No new third-party dependency is necessary. (source: request)
- TestResearchRemovalDefaults must assert the oversized shell result is at most 16384 bytes including its omission marker, and contains the bytes-omitted marker. Do not assert exact output length, marker offset, exact omitted count, head size or line layout. Rename/update the affected subtest and comments to match these guarantees. Preserve the other working-window, documentation, request-body, default-cut equality and typed-parts checks. (source: request)
- Both c6e2360290d4d8f7e124d68c4e656b38fb350d32 and cfa9b06caf24fd3b25543be9a3bd96054f536287 must pass the complete TestResearchRemovalDefaults. (source: request)

## Source comparison
- Addressed request Need 1 and Acceptance 1 through the seven-component manifest-derived check and the acceptance pin, mismatch and replacement scenarios. Historical fullscan versions are superseded as expectations, not removed component identities: coordinator e26a4d75cdcc, verification f0884fde435a, shaping f04edcea9896, build b9990a3d0903, executor 97892f55ed4f, setup 9316891471b5, review e5005fa1daf8. The supplied new build version v0.0.0-20261103231148-748c085cf3c6 is used verbatim in executable acceptance.
- Addressed request Need 2 and Acceptance 2 through the size/marker-only assertion and both loop revisions in executable acceptance. The historical failing subtest at research_removal_test.go:123 required 16384 bytes and marker at 4090..4096; line-aligned output can instead be 12303 bytes with marker at 15 and include '[... 17743 bytes omitted ...]'. Those exact-layout expectations are superseded, not a runtime cut change.
- The reported eu2/main 5cf70c29, adoption windows 20261104T002038Z and 20261104T010844Z, and 01:09Z go test ./... reproduction are diagnostic history, not requested production pin changes. No requested behavior is deliberately omitted. The present checkout still has the fullscan component pins and loop c6e2360; historical red is not asserted to describe every present test run.

## Tests
- Manifest pin adoption remains green for a matching release: run the existing TestAssemblyUsesThePinnedComponents after go get of the supplied newer build pin in a disposable source tree (regression)
- A release that differs from the source manifest is rejected: alter only the disposable packaging input to build the newer component while the test reads the original manifest and require a named component failure (integration)
- Replaced components are rejected: apply a same-version component replacement in a disposable manifest and require a named component failure (integration)
- Loop output layout is not pinned beyond its bound and marker: update the existing TestResearchRemovalDefaults cut assertion and run the full named test on each supplied loop revision (regression)
- Unrelated research defaults and all seven packaged component identities stay covered: retain the other assertions in both affected tests and run configured go-test (existing)

## Feasibility
- A focused real go test -json run observed TestResearchRemovalDefaults passing on this checkout's c6e2360; a separate real run observed TestAssemblyUsesThePinnedComponents passing before pin movement. Moving only the build module with the supplied go get version reproduced the named version-mismatch failure. Cloning the public loop repository resolved both supplied short revisions to the full hashes above. These are local command observations, not provider qualification.
- evidence: {"id":"named-test-observer","kind":"observer","inputs":["features/steps/k-adoption-tests-follow-pins__checks.js"],"observers":["features/steps/k-adoption-tests-follow-pins__checks.js"],"checks":[{"name":"good","command":"node features/steps/k-adoption-tests-follow-pins__checks.js --control good","exit":0,"output":"observer accepted\n"},{"name":"bad","command":"node features/steps/k-adoption-tests-follow-pins__checks.js --control bad","exit":1,"output":"observer rejected\n"}]}
