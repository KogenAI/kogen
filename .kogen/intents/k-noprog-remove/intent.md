# Remove the native fingerprint stop

Slug: k-noprog-remove
Model: not applicable — this removes an unused opt-in policy without changing default state transitions
Acceptance:
- .kogen/intents/k-noprog-remove/acceptance.feature
- features/steps/k_noprog_remove_steps.js

Remove K-NOPROG-REMOVE's target: the opt-in native fingerprint stop introduced in 090f36b. Delete project.Role.NoProgress, native fingerprint collection and hashing, hook installation, native_no_progress error classification, event/result fields and enabled custody plumbing. Delete tests solely of the removed policy and its unsupported-role settings. Preserve useful default-path tests by adapting them to the option-free API. Remove current documentation/specification of that option and retire the superseded k-noprog Intent's executable artifacts; a short changelog-style historical note may remain. This is not removal of the pinned library's generic Progress API or its own tests/docs: that library capability is not the removed project option and must remain unchanged.

Default configuration, emitted default role JSON and generated project configuration remain byte-identical. Default fake-provider Build behavior, CLI, other limits, external executor behavior and verification-level stops remain unchanged. Build and every configured check must pass. Do not change configured checks or protected vendored files.

## Decisions
- Remove the unused off-by-default option rather than registering a new experiment. Main's F8 rule of 29 Oct 2026 and Research LOOP-BOUNDS step 0 (0 of 960 cells with even two identical consecutive tool calls; no climb plans use it; FINDINGS row loop-noprogress-stop) motivate deletion, not a replacement heuristic. (source: request)
- Keep verification-level no_progress: a native builder answering without a tool call to the same red verification pass is distinct from repeated tool-call fingerprints. Preserve executor_no_progress and all other limits too. (source: request)
- Document that legacy project.yaml keys NoProgress and no_progress are ignored, not supported settings. Neither was a YAML option; retain the existing parser behavior rather than introducing CLI/config validation changes. Add this statement only as a removal/changelog-style note. (source: request)
- Shared-host safety: use temporary directories only for fixtures, no synthetic CPU load, and never stop processes by name or pattern; terminate only owned PIDs. (source: request)

## Source comparison
- Addressed: request Why, What to change and Acceptance through deletion of the native project option, plumbing, outcome/event, tests and current docs; historical rationale and 090f36b retained above. The Tests and acceptance scenarios cover removal and unchanged behavior.
- Addressed: Must stay through byte-identical defaults, no CLI change, preservation of other limits and the explicit documented-ignore decision for legacy project.yaml keys.
- Addressed: Host safety through the Decisions and temp-only existing test fixtures.
- Superseded: .kogen/intents/k-noprog describes the removed opt-in mechanism; retire its executable specification and enabled-policy tests, retaining at most a changelog-style note. Pinned generic library hooks are not the project option being removed and are outside this deletion.
- Omitted: no requested product behavior. No new experiment, replacement stop, provider protocol, flags or settings are added.

## Tests
- Remove the project option and native stop: acceptance scans first-party Go sources for the removed identifiers; delete obsolete enabled-policy tests and retire the old executable Intent (integration)
- Preserve default behavior and bytes: adapt the useful default portion of TestKNoProgDefault into an option-free test using the existing local fake provider, exercising four identical continuing read calls followed by finish without a stop; retain exact expected default role JSON and checkpoint/config serialization assertions (integration)
- Preserve verification-level no_progress and other limits: existing build, executor and shape package tests, including noprogress_test.go and k19_no_progress_test.go, pass unchanged except tests exclusively exercising the deleted option (existing)
- Ignore legacy YAML spellings as documented: add focused project config tests loading role mappings with NoProgress: true and no_progress: true, comparing parsed default role values and generated configuration bytes to the same input without those keys (unit)
- Build and all configured checks pass: normal configured verification, including compile, go-test, spec and chapter 04 cucumber (existing)

## Feasibility
- none
