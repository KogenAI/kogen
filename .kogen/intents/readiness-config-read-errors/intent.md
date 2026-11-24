# Distinguish config read errors from missing files

Slug: readiness-config-read-errors
Model: not applicable — this is stateless classification of a filesystem read result, preserving parsing behavior
Acceptance:
- .kogen/intents/readiness-config-read-errors/acceptance.feature
- features/steps/readiness-config-read-errors__steps.js
- features/steps/readiness-config-read-errors__driver/main.go
- features/steps/readiness-config-read-errors__driver/observe.cjs

Fix evidence ev-f796440d in cli/readiness/readiness.go and add regression coverage in cli/readiness/readiness_test.go. Replace the classification of all configuration read errors as missing with cause-appropriate reporting. A missing .kogen/project.yaml still recommends kogen init; an existing unreadable or non-regular configuration path needs a readable configuration file, not initialization. Preserve valid-config reporting and malformed-config line diagnostics. Do not change project config parsing or init behavior, or expand production changes beyond these two files.

## Decisions
- A missing config still reports that .kogen/project.yaml is missing and recommends kogen init; reserve that diagnosis for a not-exist read error, and report other read errors with the underlying cause and guidance to make the path a readable regular config file rather than running init. (decision: D1, round 1) (evidence: cli/readiness/readiness.go; cli/readiness/readiness_test.go) (source: request)
- When .kogen/project.yaml is a directory, the report identifies that the existing path cannot be read as a config file and does not report it as missing. (decision: D2, round 1) (evidence: cli/readiness/readiness.go) (source: request)
- A valid config remains reported as valid, and malformed config retains its line-specific diagnostic; keep parsing and init behavior unchanged. (decision: D3, round 1) (evidence: cli/readiness/readiness.go; cli/readiness.go) (source: request)
- Exercise the actual readiness report entry point, readiness.Run with readiness.Input, and its readiness.Text rendering against temporary filesystem fixtures; init is not used to create or repair those fixtures. The helper emits the config Check and its rendered Text as JSON, excluding unrelated install, Git and login results. (decision: D4, round 1) (evidence: cli/readiness/readiness.go; cli/readiness.go; cli/readiness/readiness_test.go) (source: request)

## Source comparison
- Addressed: Request evidence ev-f796440d and Expected distinguish a missing project config from an existing unreadable or non-regular path. Decisions D1–D2, the directory scenario and its wrong implementation cover the reproduced directory error and cause-appropriate repair guidance rather than init.
- Addressed: Request acceptance 1 and its counterexample preserve .kogen/project.yaml, the missing diagnosis and kogen init guidance exactly in the missing scenario. The missing-guidance wrong implementation must be rejected.
- Addressed: Request acceptance 3 and its counterexample preserve valid reporting and line-specific malformed diagnostics in separate executable scenarios. The valid-rejection and parse-masking wrong implementations must be rejected. The malformed fixture reaches the existing parser rather than substituting a read failure.
- Addressed: Request Scope is cli/readiness/readiness.go and cli/readiness/readiness_test.go. Production changes remain there; the Intent-owned helpers and controls are verification artifacts. Parsing and init behavior remain out of scope; neither is replaced. The report entry point is used directly because the requested change is its read-error classification, not init's orchestration.
- Omitted: no requested behavior. Conflicting: none. Superseded: only the old blanket missing-file classification for non-missing read errors, not the true missing-file behavior.

## Tests
- Missing config keeps its diagnosis and initialization guidance: preserve the existing missing-config assertion and strengthen config-report coverage in cli/readiness/readiness_test.go; acceptance compares the complete config result and rendered report (integration)
- An existing directory is a read failure with a file repair, not missing or init guidance: add a real-directory regression in cli/readiness/readiness_test.go and exercise readiness.Run and Text in the directory scenario (regression)
- Valid config remains valid: preserve existing valid-config tests and compare the complete config result and rendered report in acceptance (integration)
- Malformed config retains its line-specific diagnostic and edit guidance: add focused coverage in cli/readiness/readiness_test.go and compare the parser diagnostic and report in acceptance (regression)

## Feasibility
- The public report helper compiled and executed against the filesystem fixtures; the baseline reproduced the directory misclassification while the preservation fixtures reached their intended reporting paths. (probe 1: exit 0, 3.2 s)
- Correct and single-property-wrong overlays compiled in scratch; the correct overlay's focused config-read regression tests passed, and their actual report outputs supplied observer fixtures. Ephemeral project roots were normalized only in recorded observer data. (probe 3: exit 0, 6.3 s)
- evidence: {"id":"config-report-observer","kind":"observer","inputs":[".kogen/intents/readiness-config-read-errors/observer-fixtures.json"],"observers":["features/steps/readiness-config-read-errors__driver/observe.cjs"],"checks":[{"name":"good","command":"node features/steps/readiness-config-read-errors__driver/observe.cjs .kogen/intents/readiness-config-read-errors/observer-fixtures.json good","exit":0,"output":"accepted\n"},{"name":"bad","command":"node features/steps/readiness-config-read-errors__driver/observe.cjs .kogen/intents/readiness-config-read-errors/observer-fixtures.json bad","exit":1,"output":"rejected\n"}]}
