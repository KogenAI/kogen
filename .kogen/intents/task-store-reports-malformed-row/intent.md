# Report malformed task file rows with location

Slug: task-store-reports-malformed-row
Model: not applicable — the change is a stateless validation of each row while reading the task file
Acceptance:
- .kogen/intents/task-store-reports-malformed-row/acceptance.feature
- features/steps/task-store-reports-malformed-row__steps.js

This feature makes the Tiny Tasks store stop with a concise error when the task file holds a malformed row. Today `decode/1` in `examples/tiny_tasks/lib/tiny_tasks/store.ex` pattern-matches exactly three tab-separated fields and calls `String.to_integer/1`, so a bad row raises a match or conversion exception that does not say which row is bad. After the change, any command that reads the task file (for example `mix todo.list`) exits unsuccessfully with an error that names the task file path and the one-based line number of the first malformed row, and the file is left unchanged. Valid files load and list as before. Automatic repair of malformed data and any change to the task file format are out of scope. The change is in `examples/tiny_tasks/lib/tiny_tasks/store.ex` and `examples/tiny_tasks/test/tiny_tasks_test.exs`.

## Decisions
- A row with a number of tab-separated fields other than three is rejected with an error naming the task file path and the one-based line number of that row. (constraint: the error names the file path and the one-based line number) (constraint: the command exits unsuccessfully with a concise Mix error, not a match or conversion exception) (evidence: examples/tiny_tasks/lib/tiny_tasks/store.ex) (source: request)
- A row whose ID field is not a whole decimal integer (for example `abc` or `2x`) is rejected the same way, with the file path and one-based line number, instead of a `String.to_integer/1` exception. (constraint: the error names the file path and the one-based line number) (evidence: examples/tiny_tasks/lib/tiny_tasks/store.ex) (source: request)
- The original file remains unchanged when a row is rejected: the store never writes the file while reading, and the error is raised before any write. (constraint: the task file is byte-for-byte unchanged, not replaced and not rewritten) (evidence: examples/tiny_tasks/lib/tiny_tasks/store.ex; examples/tiny_tasks/lib/tiny_tasks.ex) (source: request)
- The line number counts every line of the file, including blank lines that the reader skips, so it matches the line an editor shows. The error is raised with `Mix.raise` (a probe compiled it without warnings under `mix compile --warnings-as-errors` and printed `** (Mix) Malformed task row at <path>:<line>`), matching the existing `Invalid task ID` style; the exact wording is the builder's choice provided it contains the file path and the line number as `<path>:<line>` or `line <line>`. (evidence: examples/tiny_tasks/lib/tiny_tasks/store.ex; examples/tiny_tasks/lib/mix/tasks/todo/complete.ex) (assumption: the exact message wording and the use of Mix.raise are not specified by the request; a scratch probe of this shaping showed the error printed without a stack trace) (source: request)
- A valid task file continues to load and list tasks in stored order with unchanged decoding; no setting, option or file format change is added, and malformed rows are never repaired or skipped. (constraint: valid decoding and stored order unchanged) (evidence: examples/tiny_tasks/test/tiny_tasks_test.exs; examples/tiny_tasks/lib/tiny_tasks/store.ex) (source: request)
- Malformed rows (wrong field count) are rejected with the file path and one-based line number (decision: D1, round 1) (constraint: error names path and line) (constraint: concise Mix error) (evidence: examples/tiny_tasks/lib/tiny_tasks/store.ex) (source: request)
- Nonnumeric IDs rejected with path and line via Integer.parse (decision: D2, round 1) (evidence: examples/tiny_tasks/lib/tiny_tasks/store.ex) (source: request)
- File unchanged on rejection (decision: D3, round 1) (evidence: examples/tiny_tasks/lib/tiny_tasks.ex) (source: request)
- Line numbers count blank lines; Mix.raise used (decision: D4, round 1) (evidence: examples/tiny_tasks/lib/mix/tasks/todo/complete.ex) (assumption: Scratch probe showed Mix.raise in store.ex compiles with --warnings-as-errors and prints '** (Mix) Malformed task row at <path>:<line>'; wording is builder's choice.) (source: request)
- Valid files unchanged, no repair or format change (decision: D5, round 1) (evidence: examples/tiny_tasks/test/tiny_tasks_test.exs) (source: request)

## Source comparison
- Wrong number of fields rejected with file path and one-based line, file unchanged: addressed by D1, D3, D4 and the scenarios "A row with too few fields is rejected with its location" and "A row after a blank line is reported with its file line number".
- Nonnumeric ID rejected with file path and one-based line, file unchanged: addressed by D2, D3 and the scenarios "A nonnumeric ID is rejected with its location" and "An ID with a numeric prefix is rejected with its location".
- Valid task file keeps loading and listing in stored order: addressed by D5 and the scenario "A valid task file lists tasks in stored order".
- Automatic repair of malformed data and task file format changes: out of scope, see D5.
- The raw match/conversion exception as the reported behavior: superseded by the located error.

## Tests
- A row with the wrong number of fields is rejected with the file path and one-based line number, file unchanged: add a case to examples/tiny_tasks/test/tiny_tasks_test.exs that writes a malformed task file and runs the real mix command with TODO_FILE (integration)
- A row with a nonnumeric ID is rejected with the file path and one-based line number, file unchanged: add a case to examples/tiny_tasks/test/tiny_tasks_test.exs running the real mix command (integration)
- A valid task file still lists tasks in stored order: the existing TASK-2 listing tests in examples/tiny_tasks/test/tiny_tasks_test.exs (existing)
- All malformed-row and valid-file behavior through the real Mix CLI: the acceptance.feature scenarios (scenario)

## Feasibility
- none
