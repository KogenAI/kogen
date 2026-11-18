# Accept both no-commits texts in the init spec

Slug: spec-init-no-commits-names-uncommitted-paths
Model: not applicable — the change edits one assertion in a static feature file and has no meaningful runtime state
Acceptance:
- .kogen/intents/spec-init-no-commits-names-uncommitted-paths/acceptance.feature
- features/steps/spec-init-no-commits-names-uncommitted-paths__steps.js

The release acceptance scenario "Init in a repository whose files are not committed yet asks for the first commit" in `spec/features/01-project-setup.feature` (tag `@SET-2`, the scenario that writes `app.txt` with the step `the file "app.txt" is changed outside Kogen` and runs `kogen init`) compares all of stdout with the old refusal text. The landed producer now names the uncommitted file, while the vendored producers of main still print the old text until the release adopts the new component heads. The change is backward compatible, as the precedent commit eab9297 was for other frozen-producer fixtures, so this repository's own checks pass before and after adoption. The assertion must hold for exactly two lines, and nothing else:

- old: `environment/no_commits: 1 file(s) are not committed yet; commit them first (git add -A && git commit -m "Initial commit"), then run kogen init`
- new: `environment/no_commits: 1 file(s) are not committed yet (app.txt); commit them first (git add -A && git commit -m "Initial commit"), then run kogen init`

A different message must still fail, for example a different path:

- rejected: `environment/no_commits: 1 file(s) are not committed yet (other.txt); commit them first (git add -A && git commit -m "Initial commit"), then run kogen init`

or a line that misses the commit hint, such as `environment/no_commits: 1 file(s) are not committed yet (app.txt)`. A bare `stdout contains "no_commits"` is not acceptable.

The change replaces the `And stdout is:` block of that one scenario by the existing step `stdout matches` with an anchored regular expression that allows the optional ` (app.txt)` group and nothing else. The regular expression is written without backslashes except `\x22` for the double quotes (the step pattern forbids a literal double quote inside the string):

`And stdout matches "^environment/no_commits: 1 file[(]s[)] are not committed yet([ ][(]app[.]txt[)])?; commit them first [(]git add -A && git commit -m \x22Initial commit\x22[)], then run kogen init$"`

The scenario keeps `Then the exit code is 3`, its fixture `empty-repo` and its tag. No other line of the feature, no step file, no handler, no other scenario changes; no scenario is removed, skipped or tagged away. `cli/go.mod`, `cli/go.sum`, `cli/loop-pin.json`, the vendored component trees, `.kogen/project.yaml`, checks and protections are not edited; component adoption is the release workflow's job.

The builder runs the maintained suite and reports the exact commands and results: the scenario at its line (`cd test/acceptance && npx cucumber-js --strict --tags "not @live" --require "steps/*.js" --require "support/*.js" ../../spec/features/01-project-setup.feature:285`, adjusted to the scenario's current line) and the whole feature (the same command without the line suffix), plus the configured `spec` check.

## Decisions
- Use one existing `stdout matches` step with an anchored regex with one optional ` (app.txt)` group (decision: D1, round 1) (constraint: anchored ^ and $) (constraint: no backslash other than \x22) (evidence: spec/features/STEPS.md; test/acceptance/support/handlers.js; spec/features/01-project-setup.feature) (assumption: The real release output was not run; the new text comes from the request.) (source: request)
- Acceptance replays the scenario's assertions independently against old, new and rejected lines (decision: D2, round 1) (constraint: no production, handler or protected path change) (evidence: features/steps/qualify-frozen-corrective-consumer__steps.js; test/acceptance/support/handlers.js) (assumption: A scratch simulation with a stubbed cucumber module (not Kogen's readiness) showed correct passes and each wrong overlay fails its named step.) (source: request)

## Source comparison
- Request expected 1 (replace the exact block by an assertion accepting exactly the old and the new text, keep exit code 3): addressed in the one scenario of `spec/features/01-project-setup.feature`; acceptance scenarios 1, 2 and 3 replay it.
- Request expected 2 (nothing else changes, nothing removed, skipped or tagged away): addressed by the scope scenario, which compares the feature file with HEAD outside the stdout assertion, checks the scenario count (21), the `@SET-2` tag, and that only the feature file and this Intent's files change.
- Request expected 3 (no edit to cli/go.mod, cli/go.sum, cli/loop-pin.json, vendored trees, .kogen/project.yaml, checks, protections): omitted from the change; the scope scenario rejects any other changed file.
- Request acceptance scenarios 1 (old text passes), 2 (new text with ` (app.txt)` passes) and 3 (`(other.txt)` or a missing commit hint fails): acceptance scenarios 1, 2 and 3; the control wrong implementations are, in order, new-text-only, the kept exact old block, and a bare `stdout contains "no_commits"`.
- Request's report of exact commands and results: stated above for the builder.

## Tests
- The scenario accepts the old text printed by the current vendored producer: scenario 1 of acceptance.feature (scenario)
- The scenario accepts the new text naming app.txt: scenario 2 of acceptance.feature (scenario)
- The scenario rejects other paths, a missing commit hint and every other variation: scenario 3 of acceptance.feature (scenario)
- Nothing else in the feature changes and no protected path is edited: scenario 4 of acceptance.feature (scenario)
- The maintained scenario and the whole 01-project-setup feature: the cucumber run of spec/features/01-project-setup.feature (existing)

## Feasibility
- none
