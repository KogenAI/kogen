# Cover successful usage lineage selection

Slug: usage-lineage-success-coverage
Model: not applicable — the change only adds a test; no stateful behavior is introduced
Acceptance:
- .kogen/intents/usage-lineage-success-coverage/acceptance.feature
- features/steps/usage-lineage-success-coverage__mut.js

Add model-free Go test coverage in cli/usage_test.go for successful `--lineage` selection through the usage command across a resumed run chain. The fixture has metadata for an original run, its resumed run, a sibling sharing the same root build, and an unrelated run. Querying the resumed run with `--lineage --json` must return usage from the original, resumed and sibling runs and exclude the unrelated run, and the JSON scope must identify the requested run id and report lineage selection enabled.

Out of scope: any change to lineage selection rules (cli/usage.go stays untouched) and to other usage filters. Only cli/usage_test.go changes in production tree.

## Decisions
- The new test goes into cli/usage_test.go only and drives the usage command through the existing `TestLocalReadProcess` subprocess mechanism with `intent usage <resumed-run> --lineage --json --project <root>`, using `factProject` for the fixture project. (evidence: cli/usage_test.go; cli/facts_test.go) (source: request)
- Acceptance observes the test's strength by mutation: it copies cli/ to a scratch directory, confirms the Go tests defined in usage_test.go pass on the unmodified command, then applies one defect to the copy's usage.go and requires those tests to fail with a test failure. Defects: selecting only the requested run, selecting every run, reporting scope lineage as false, omitting the run id from the scope, ignoring the shared root_build, and not following resumed_from to the original run. This avoids naming a test the Build must invent. (evidence: cli/usage.go) (source: request)
- Selection semantics asserted are those the code has now: the chain is followed up through resumed_from to the original run, then every run resumed from a selected run or sharing that root_build is selected. No rule changes. (evidence: cli/usage.go) (source: request)
- Run ids in the fixture are 8 lowercase hex characters, as the command requires. (evidence: cli/facts.go) (source: request)
- Add the lineage test to cli/usage_test.go only; acceptance proves coverage strength by applying defects to a scratch copy of usage.go and requiring the usage tests to fail. (decision: D1, round 1) (constraint: cli/usage.go unchanged in the real tree) (evidence: cli/usage.go; cli/usage_test.go; cli/facts_test.go) (assumption: Local scratch run showed the correct test passes and each mutant fails; Kogen readiness is the authoritative check.) (source: request)

## Source comparison
- Acceptance 1 (original, resumed, sibling and unrelated runs; related usage returned, unrelated excluded): addressed by the selecting-only-requested-run and selecting-every-run scenarios, plus root_build and resumed_from scenarios.
- Acceptance 2 (scope identifies requested run id and lineage enabled): addressed by the scope scenarios.
- Out of scope (lineage rules, other filters): usage.go is not edited; mutations occur only on a scratch copy.

## Tests
- Successful --lineage selection across a resumed chain returns the original, resumed and sibling runs and excludes the unrelated run: a Go test in cli/usage_test.go running the usage command with --json (integration)
- The JSON scope reports the requested run id and lineage true: the same Go test (integration)
- The coverage is strong enough to catch wrong selection and scope: mutation scenarios in acceptance.feature (scenario)

## Feasibility
- none
