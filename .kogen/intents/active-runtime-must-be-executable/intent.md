# Require executable active runtimes

Slug: active-runtime-must-be-executable
Model: not applicable — Active selects from a filesystem snapshot; this change adds no meaningful state or transitions.
Acceptance:
- .kogen/intents/active-runtime-must-be-executable/acceptance.feature
- features/steps/active-runtime-must-be-executable__steps.js
- features/steps/active-runtime-must-be-executable__driver/main.go

Make Active fall back to the pinned version and path when the newer active runtime is a regular file without executable permission bits. Preserve the active version and path for an executable regular file. Replace the regular-file-only eligibility check with a regular-and-executable check and add a direct regression test. Production changes are limited to cli/internal/claudecode/update.go and cli/internal/claudecode/update_test.go. Runtime selection by version, runtime probing, and update installation are out of scope.

## Decisions
- Determine executability from whether any executable permission bit is set, while retaining the regular-file requirement; Active continues to run nothing. (evidence: cli/internal/claudecode/update.go) (source: request)
- Add direct regression coverage calling Active with real temporary files for both permission outcomes, retaining useful existing coverage. (evidence: cli/internal/claudecode/update_test.go) (source: request)

## Source comparison
- Addressed: request evidence ev-f7bf977e identifies Active's documented executable requirement and regular-file-only check in cli/internal/claudecode/update.go; the outcome above and the non-executable acceptance scenario close that gap.
- Addressed: request acceptance 1 requires the pinned version and path for a newer active regular file with no executable permission bits; acceptance.feature checks both returned fields and rejects the regular-file-only implementation.
- Addressed: request acceptance 2 requires the same newer version to remain active when executable; acceptance.feature checks both returned fields and rejects unconditional pin fallback.
- Addressed: request requires a direct regression test in cli/internal/claudecode/update_test.go, as specified above and in Tests; acceptance also directly invokes Active through a compiled Go helper.
- Addressed: request scope is limited to cli/internal/claudecode/update.go and cli/internal/claudecode/update_test.go; runtime selection by version, runtime probing, and update installation are explicitly unchanged. No requested behavior is omitted or superseded.

## Tests
- Non-executable active runtime fallback: add a direct Active regression using a regular file with no executable permission bits and assert the pinned version and path (regression)
- Executable active runtime retention: preserve or extend direct Active coverage to assert the newer active version and path for an executable regular file (integration)

## Feasibility
- none
