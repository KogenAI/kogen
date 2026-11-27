# Report usage when task arguments are missing

Slug: missing-task-arguments-report-usage
Model: not applicable — the change is a stateless argument check in two command-line entry points
Acceptance:
- .kogen/intents/missing-task-arguments-report-usage/acceptance.feature
- features/steps/missing-task-arguments-report-usage__steps.js

This feature makes `mix todo.add` and `mix todo.complete`, when run without their required argument, fail with a concise command-specific error instead of a function-clause exception. Today neither command handles an empty argument list, so Mix reports a FunctionClauseError. The change is in `examples/tiny_tasks/lib/mix/tasks/todo/add.ex`, `examples/tiny_tasks/lib/mix/tasks/todo/complete.ex` and `examples/tiny_tasks/test/tiny_tasks_test.exs`. Valid command syntax and task persistence are unchanged.

## Decisions
- `mix todo.add` with no arguments exits unsuccessfully with a concise message that names the missing title, and does not create the task file. (evidence: examples/tiny_tasks/lib/mix/tasks/todo/add.ex; examples/tiny_tasks/lib/tiny_tasks/store.ex) (source: request)
- `mix todo.complete` with no arguments exits unsuccessfully with a concise message that names the missing ID, and leaves an existing task file byte-for-byte unchanged. (decision: D2, round 1) (evidence: examples/tiny_tasks/lib/mix/tasks/todo/complete.ex; examples/tiny_tasks/lib/tiny_tasks/store.ex) (source: request)
- The error is raised with `Mix.raise` before `app.start`, matching the existing `Invalid task ID` error style, so the exit status is nonzero and no store access happens; the exact wording is the builder's choice provided it contains the word `title` (add) or `ID` (complete) and is not a function-clause failure. (decision: D3, round 1) (evidence: examples/tiny_tasks/lib/mix/tasks/todo/complete.ex) (assumption: the exact message wording is not specified by the request) (source: request)
- Argument shapes other than the empty list (valid syntax, extra arguments) keep their current behavior; no new options or settings are added. (decision: D4, round 1) (evidence: examples/tiny_tasks/lib/mix/tasks/todo/add.ex; examples/tiny_tasks/lib/mix/tasks/todo/complete.ex) (source: request)
- todo.add with no arguments raises a Mix error naming the missing title before app.start; todo.complete with no arguments raises a Mix error naming the missing ID before app.start; no task file is created or modified. (decision: D1, round 1) (constraint: Valid syntax and persistence unchanged) (constraint: message contains the word title (add) or ID (complete) and is not a function-clause failure) (evidence: examples/tiny_tasks/lib/mix/tasks/todo/add.ex; examples/tiny_tasks/lib/mix/tasks/todo/complete.ex; examples/tiny_tasks/lib/tiny_tasks/store.ex) (assumption: Exact message wording is the builder's choice; a probe showed the unchanged tree fails with FunctionClauseError for both commands.) (source: request)

## Source comparison
- Missing title for todo.add: addressed by D1 and the scenario "todo.add without a title reports a usage error".
- Missing ID for todo.complete: addressed by D2 and the scenario "todo.complete without an ID reports a usage error and keeps the file".
- Out of scope (changing valid command syntax or task persistence): unchanged, see D4.
- The function-clause failure as the reported behavior: superseded by the specific errors.

## Tests
- todo.add without a title fails, names the title and creates no task file: add a case to examples/tiny_tasks/test/tiny_tasks_test.exs running the real mix command with a temporary TODO_FILE (integration)
- todo.complete without an ID fails, names the ID and leaves an existing task file unchanged: add a case to examples/tiny_tasks/test/tiny_tasks_test.exs running the real mix command (integration)
- Both missing-argument behaviors through the real Mix CLI: the acceptance.feature scenarios (scenario)

## Feasibility
- none
