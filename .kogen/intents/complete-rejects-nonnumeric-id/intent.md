# Refuse nonnumeric IDs in todo.complete

Slug: complete-rejects-nonnumeric-id
Model: not applicable — the change is a single input check on a command; the observable behavior is one refusal with no state to model
Acceptance:
- .kogen/intents/complete-rejects-nonnumeric-id/acceptance.feature
- features/steps/complete-rejects-nonnumeric-id__steps.js

From `examples/tiny_tasks`, `mix todo.complete ID` with an ID that is not a number (for example `abc`, or `2x` which only starts with a digit) exits unsuccessfully with a concise error that names the supplied ID and says it is invalid, instead of raising an implementation exception from `String.to_integer/1`. The task file is not written: its bytes and modification time stay unchanged. Completing an unknown numeric ID keeps its existing refusal (unsuccessful exit, a message that the task was not found, file unchanged), and completing a known ID behaves as before. Out of scope: the task storage format and completion behavior for valid IDs.

Implementation scope: `examples/tiny_tasks/lib/mix/tasks/todo/complete.ex` and `examples/tiny_tasks/test/tiny_tasks_test.exs` (a new ExUnit case next to the existing unknown-ID case).

## Decisions
- A nonnumeric ID is refused with an unsuccessful exit and a message that contains the supplied ID and the word "invalid"; the exact sentence is otherwise free. (source: request)
- The whole argument must be an integer: a value that merely starts with digits, such as `2x`, is nonnumeric and is refused without completing any task. (assumption: the user agrees a numeric prefix does not make an ID numeric) (source: request)
- The refusal happens before any task file access, so the file bytes and modification time stay unchanged. (source: request)
- Unknown numeric IDs keep reporting that the task was not found, distinct from the invalid-ID message. (evidence: examples/tiny_tasks/lib/mix/tasks/todo/complete.ex; examples/tiny_tasks/test/tiny_tasks_test.exs) (source: request)
- The invalid-ID refusal uses the same Mix.raise mechanism as the existing not-found refusal, so no new option or output stream is introduced. (evidence: examples/tiny_tasks/lib/mix/tasks/todo/complete.ex) (source: request)

## Source comparison
- Addressed — Request evidence `ev-e759fbce` and Expected: the nonnumeric scenarios (`abc`, `2x`) require an unsuccessful exit, no implementation exception text, an invalid-ID report naming the ID, and unchanged file bytes and mtime (file set to year 2000 beforehand so any rewrite is visible).
- Addressed — Request acceptance 2: the unknown-ID scenario (`99`) requires an unsuccessful exit, a "not found" report naming the ID, no "invalid" wording, and an unchanged file.
- Preserved — Out of scope items: storage format and valid-ID completion are untouched; the existing completion tests stay.

## Tests
- A nonnumeric ID is refused with an invalid-ID message naming it and leaves the file untouched: add an ExUnit case in `examples/tiny_tasks/test/tiny_tasks_test.exs` modeled on the existing unknown-ID case (integration)
- Unknown numeric ID still reports not found and leaves the file unchanged: the existing unknown-ID test (existing)
- End-to-end through the real Mix command with a temporary `TODO_FILE`: the three acceptance scenarios (scenario)

## Feasibility
- none
