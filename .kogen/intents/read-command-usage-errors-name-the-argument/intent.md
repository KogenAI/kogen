# Name the refused argument in read command errors

Slug: read-command-usage-errors-name-the-argument
Model: not applicable — the change only rewords the detail of a stateless refusal
Acceptance:
- .kogen/intents/read-command-usage-errors-name-the-argument/acceptance.feature
- features/steps/read-command-usage-errors-name-the-argument__steps.js

Every `invalid_argument` answer of `kogen intent list`, `kogen intent inspect`, `kogen intent preflight`, `kogen intent usage` and `kogen context` names the wrong argument and what was expected in `error.detail`. Today the detail is the reason code repeated (`invalid_argument`). The detail becomes one sentence: the text `kogen`, a space, the command path (`intent list`, `intent inspect`, `intent preflight`, `intent usage` or `context`), a colon and a space, then exactly one of these texts, identical for every command that has the option:

- an option the command lacks (including `--limit` and `--cursor` on every command but `intent list`; `--json` or any option written with `=` that the command does not take as such, as today): `unknown option '--bogus'`, naming the option with its two dashes and without any value (`--bogus=1` is named `--bogus`)
- an option whose value is missing as the last word: `--project needs a value`
- a limit that is not a whole number from 1 to 100: `--limit must be a whole number from 1 to 100`
- a cursor that does not decode or belongs to another list: `--cursor is not a cursor of the current list`
- the first positional beyond the expected count, naming it: `unexpected argument 'extra'`
- no run id for inspect: `missing the run id`; no slug for preflight: `missing the slug`
- an invalid slug: `the slug must be 3 to 48 characters and use lowercase letters, digits and dashes`
- lineage without a run id: `--lineage needs a run id`
- an unknown group-by field, naming the first unknown one: `--group-by field 'bogus' is unknown (fields: project, slug, lineage, phase, role, model, effective-model, effort, effective-effort, outcome, pass, repair)`
- a since or until value that is not UTC: `--since must be a UTC time such as 2026-11-16T00:00:00Z`, with the option's own name (`--until` for until)

With several problems the first is reported: option problems in command-line order, then the positional count (an extra argument before a missing one), then lineage without a run id, then the slug.

Unchanged: the accepted and refused command lines (no new option, flag or setting); every other field of these answers (reason `invalid_argument`, class `intent`, paths `[]`, kind, checkout, data, exit code 2) and no field added; option and usage answers still come before the project lookup, the slug answer and the cursor answer after it; completion, the internal complete helper, the `not_project`, `project_unavailable`, `local_data_invalid` and `run_not_found` answers, help pages and standard error. The change may touch `cli/facts.go`, `cli/usage.go`, `cli/facts_test.go` and `spec/reference/checkout-facts.md`; in that spec, next to the sentence that says usage is 2 (`intent/invalid_argument`), add one sentence saying the `error.detail` of an `invalid_argument` answer names the argument and what was expected. No other doc changes. Do not touch `cli/go.mod`, `cli/go.sum`, `cli/loop-pin.json` or `cli/third_party/kogen-loop`.

## Decisions
- The detail is `kogen <command path>: <text>` with the texts listed above, built in one place in `cli/facts.go` and used by both `localRead` and `usageCommand`; the internal complete helper keeps the bare reason. (constraint: reason, class, paths, kind, checkout, data and exit code 2 stay as today; no field is added) (evidence: cli/facts.go; cli/usage.go) (source: request)
- An option the command lacks is reported as unknown before its value is looked at, so an unknown option written as the last word is `unknown option`, not `needs a value`; only options the command takes get `needs a value`. (evidence: cli/facts.go; cli/usage.go) (assumption: the request does not say which text wins for an unknown option written as the last word; unknown option is recommended because the option is refused whatever its value) (source: request)
- The first problem wins: options are checked in command-line order and answered at once; a positional that is wrong (extra beyond the count, or a bad positional of usage) is reported only after all options were read, so an option problem later in the line wins over an earlier extra positional; then the missing run id or slug; then lineage without a run id; then, after the project lookup, the slug. (constraint: option and usage answers come before the project lookup; slug and cursor answers after it) (evidence: cli/facts.go; cli/usage.go) (source: request)
- Acceptance runs the real `run` entry through a scratch Go test injected into package main with a go build overlay (compiled once with `go test -c`), so it needs no test name the Build must invent; the four Go unit tests named under Tests are written by the Build in `cli/facts_test.go` and are not run by acceptance. (evidence: features/steps/build-context-refusal-names-file-and-reason__steps.js; cli/facts_test.go) (source: request)
- The operation handles no collection of records (it only refuses arguments), so no scenario compares work at two record counts. (evidence: cli/facts.go) (source: request)
- The detail is `kogen <command path>: <text>` built in one place in cli/facts.go and used by localRead and usageCommand; the complete helper keeps the bare reason. (decision: D1, round 1) (constraint: reason, class, paths, kind, checkout, data and exit code 2 unchanged) (constraint: no field added) (evidence: cli/facts.go; cli/usage.go) (source: request)
- An option the command lacks is reported as unknown before its value is examined, so an unknown option written last is unknown option, not needs a value. (decision: D2, round 1) (evidence: cli/facts.go; cli/usage.go) (assumption: The request does not say which text wins for an unknown option written as the last word; unknown option recommended.) (source: request)
- First problem wins: options in command-line order, then extra positional, then missing run id or slug, then lineage without run id, then slug after project lookup. (decision: D3, round 1) (constraint: option and usage answers before project lookup) (constraint: slug and cursor answers after it) (evidence: cli/facts.go; cli/usage.go) (source: request)
- Acceptance runs the real run entry through a scratch Go test injected via a go build overlay and compiled once with go test -c; the four named unit tests are written by the Build and not run by acceptance. (decision: D4, round 1) (evidence: features/steps/build-context-refusal-names-file-and-reason__steps.js; cli/facts_test.go) (assumption: A scratch probe in this session ran the correct overlay on six command lines and showed the expected details; the full acceptance and the wrong overlays were not run.) (source: request)
- No collection scenario: the operation only refuses arguments. (decision: D5, round 1) (evidence: cli/facts.go) (source: request)

## Source comparison
- Unknown option, missing value, extra positional, missing run id or slug, invalid slug, limit, cursor, lineage, group-by and since/until texts: addressed by the scenarios of acceptance.feature (request, Expected list); the `until` text with its own name has its own scenario.
- Order of problems: addressed by the scenario "An option problem is reported before an extra positional" and by the two-id and slug scenarios; the order missing-before-lineage and similar combinations are specified in prose and left to the unit tests.
- Unit test names TestReadCommandsNameOptionsAndPositionals, TestInspectAndPreflightNameMissingAndInvalid, TestListAndUsageNameLimitAndCursor, TestUsageNamesTheRefusedFilter in cli/facts_test.go: addressed under Tests (they are written by the Build next to TestInspectUnknownRunNamesNextCommand using factProject, captureStdout and localRead).
- Completion and the complete helper, other answers, help pages, standard error: unchanged, omitted by request.
- Spec sentence in spec/reference/checkout-facts.md: addressed in prose; no scenario reads the spec.

## Tests
- Unknown options and extra positionals are named (`intent inspect --bogus=1 0a1b2c3d`, `intent list --project`, `context --cursor=x`, `intent list extra`): TestReadCommandsNameOptionsAndPositionals in cli/facts_test.go calls localRead and compares only the error detail (unit)
- Missing and invalid positionals are named (two run ids, no run id, no slug, `Is_Even`, using a factProject project): TestInspectAndPreflightNameMissingAndInvalid in cli/facts_test.go (unit)
- Limit and cursor texts (`--limit 0`, `--limit x`, usage `--limit 101`, list `--cursor=x` with a project): TestListAndUsageNameLimitAndCursor in cli/facts_test.go (unit)
- Usage filters (`--lineage`, `--group-by phase,bogus`, `--since 2026-11-16`): TestUsageNamesTheRefusedFilter in cli/facts_test.go (unit)
- Every detail above through the real command entry, with the other error fields unchanged: the scenarios of .kogen/intents/read-command-usage-errors-name-the-argument/acceptance.feature (scenario)
- The spec sentence about the error detail: spec/reference/checkout-facts.md, checked by the existing spec check (existing)

## Feasibility
- none
