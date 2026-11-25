# Add the open-task list filter

Slug: tiny-tasks-open-task-filter
Model: not applicable — listing selects from an existing snapshot without a state transition
Acceptance:
- .kogen/intents/tiny-tasks-open-task-filter/acceptance.feature
- features/steps/tiny-tasks-open-task-filter__steps.js

From `examples/tiny_tasks`, `mix todo.list --open` lists only open tasks in their stored insertion order. Plain `mix todo.list` still lists every task in that order. Both succeed for a valid task file and print one `<id> [<status>] <title>` line per selected task to stdout. When the selected list is empty, print only `No tasks yet.` instead. This replaces argument-ignoring behavior for the `--open` invocation; no new behavior for other arguments is specified.

Implementation scope: `examples/tiny_tasks/lib/mix/tasks/todo/list.ex` and `examples/tiny_tasks/test/tiny_tasks_test.exs`. Keep listing read-only and preserve task storage and task completion unchanged.

## Decisions
- With a task file containing open and done tasks, mix todo.list --open prints only open tasks in their stored order; sorting or including a done task is wrong. (evidence: examples/tiny_tasks/FEATURE-REQUEST.md; examples/tiny_tasks/lib/tiny_tasks/store.ex) (source: request)
- When no tasks are open, the command prints No tasks yet. Apply the existing empty-list response to the selected list. (evidence: examples/tiny_tasks/lib/mix/tasks/todo/list.ex) (source: request)
- Plain mix todo.list still prints both open and done tasks in stored order using the existing rendering. (evidence: examples/tiny_tasks/lib/mix/tasks/todo/list.ex; examples/tiny_tasks/test/tiny_tasks_test.exs) (source: request)
- Keep listing on the existing task file, including the TODO_FILE override and existing default, and leave that file unchanged. (evidence: examples/tiny_tasks/lib/mix/tasks/todo/list.ex; examples/tiny_tasks/lib/tiny_tasks/store.ex) (source: request)

## Source comparison
- Addressed — `ev-1d1b58bb`, `examples/tiny_tasks/FEATURE-REQUEST.md` TASK-2 and Request acceptance 1: the mixed-file scenario invokes `mix todo.list --open` and checks exact open task lines in deliberately unsorted stored order, rejecting sorting and inclusion of a done task.
- Addressed — Request acceptance 2 and the existing `list.ex` empty response: the all-done scenario requires the exact stdout `No tasks yet.`, rejecting completed lines and silent output.
- Addressed — Request acceptance 3 and `FEATURE-REQUEST.md` BASE-2: the mixed-file scenario first checks plain `mix todo.list` on the same file for every ordered line, rejecting a default filter.
- Superseded only for `--open` — `list.ex` currently ignores arguments; that invocation now selects open tasks. No new flag or error behavior is added beyond TASK-2.
- Omitted deliberately — implementing TASK-1 completion or changing storage is out of scope. BASE-1 and existing TASK-1 behavior and tests stay intact; the example's independent qualification suite is not part of this delivery.

## Tests
- Select open tasks without reordering: add focused ExUnit coverage through callable Mix.Tasks.Todo.List.run/1 with the open flag, a mixed temporary TSV and captured Mix shell info lines asserting the full ordered result (unit)
- Print the empty message when the filtered result is empty: add a focused ExUnit case through the same callable task with a done-only temporary TSV, asserting the one exact info line (unit)
- Preserve plain mixed listing: keep the existing TASK-1 ordered plain-list assertion and its setup, alongside the BASE-1 and BASE-2 case (existing)
- Deliver the exact formatted results through the actual Mix CLI and local file: run the mixed-file plain and filtered invocations and the all-done filtered invocation through the feature scenarios (scenario)
- none: no record-scaled store calls for the new operation; selecting already loaded records adds no store or service work, and the existing file reader loads the task file as a whole regardless of record count

## Feasibility
- Local Mix 1.20.4 on OTP 29 and Node 24.21.0 are available (tool probe: exit 0, 0.5 s); the example's OTP check also returned 29 (exit 0, 0.3 s). The Tiny Tasks project has no dependencies. (evidence: examples/tiny_tasks/.tool-versions; examples/tiny_tasks/mix.exs)
- With a temporary `TODO_FILE`, the baseline printed both statuses for both commands. A cold plain run prefixed stdout with `Compiling 5 files (.ex)` and `Generated tiny_tasks app`; acceptance removes only those leading diagnostic shapes before comparing exact listing bytes. An empty baseline file printed `No tasks yet.`. `cd examples/tiny_tasks && mix format --check-formatted && mix test --warnings-as-errors` passed all three existing tests (baseline probe: exit 0, 8.5 s); rerun these subproject checks during Build in addition to the configured checks.
- A focused probe confirmed `Mix.Tasks.Todo.List.run/1` delivers a `{:mix_shell, :info, [line]}` message per line through Mix.Shell.Process, and confirmed Kogen Node 24.21.0 and Cucumber 13.3.0 (exit 0, 1.0 s). Use the existing serial ExUnit module, isolating and restoring the shell and `TODO_FILE` for callable tests.
- Scratch generation produced the correct and five isolated wrong overlays in `controls.json` (generation and refinement probes: exit 0, 0.1 s each). Acceptance uses `mix` on PATH, the example directory and a temporary `TODO_FILE` per scenario in the dev Mix environment.
- The final step bytes accepted the good listings and rejected all bad listings (observer probe: exit 0, 0.1 s; the bad invocation itself exited 1).
- evidence: {"id":"open-list-observer","kind":"observer","inputs":[],"observers":["features/steps/tiny-tasks-open-task-filter__steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/tiny-tasks-open-task-filter__steps.js good","exit":0,"output":"good listings accepted\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/tiny-tasks-open-task-filter__steps.js bad","exit":1,"output":"all bad listings rejected\n"}]}
