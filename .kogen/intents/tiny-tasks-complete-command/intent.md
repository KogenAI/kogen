# Complete a task from the Tiny Tasks CLI

Slug: tiny-tasks-complete-command
Model: .kogen/intents/tiny-tasks-complete-command/model.qnt invariants=StableIdentitiesAndOrder,OnlySelectedTaskChanges,UnknownPreservesState seed=41 samples=100 steps=8
Acceptance:
- .kogen/intents/tiny-tasks-complete-command/acceptance.feature
- features/steps/tiny-tasks-complete-command__steps.js

From `examples/tiny_tasks`, run `mix todo.complete ID` with one numeric task ID. For an open task, exit successfully after persisting the new status. A separate plain `mix todo.list` shows every task in insertion order as `<id> [<status>] <title>`, with `done` for the completed task. For an unknown ID, exit unsuccessfully with a diagnostic naming the offending ID. Do not write or replace the task file on a miss. No exact success or error sentence is required. Malformed arguments and requests to complete an already-done task have no new stated behavior.

Implementation scope: `examples/tiny_tasks/lib/tiny_tasks.ex`, `examples/tiny_tasks/lib/mix/tasks/todo/complete.ex`, and `examples/tiny_tasks/test/tiny_tasks_test.exs`. No existing command is removed. Reuse the existing ordered local file, `TODO_FILE` override and default `~/.tiny_tasks/tasks.tsv`; preserve the existing TSV encoding (ID, status and Base64-encoded title). No `mix todo.list --open` or other list filtering, storage format change, dependency, or config change. The existing file and Mix command conventions are grounded in the tracked files cited below.

## Decisions
- Running mix todo.complete with an open task ID changes that task to done and preserves its ID, title, position, and every other task. (source: request)
- Completing an unknown ID reports the offending ID and leaves the task file unchanged. (source: request)
- Keep completion on the existing ordered task store and use the stored ID to select the record. (decision: D1, round 1) (evidence: examples/tiny_tasks/lib/tiny_tasks.ex; examples/tiny_tasks/lib/tiny_tasks/store.ex) (source: request)
- Preserve the task file format and plain list rendering, including the existing TODO_FILE override. (evidence: examples/tiny_tasks/lib/tiny_tasks/store.ex; examples/tiny_tasks/lib/mix/tasks/todo/list.ex) (source: request)
- Report a missing ID as an unsuccessful Mix command with a diagnostic that names the offending ID. Output stream and wording are not fixed. (source: request)
- Successful completion needs no fixed confirmation text. (evidence: examples/tiny_tasks/FEATURE-REQUEST.md) (source: request)

## Source comparison
- Addressed — evidence `ev-e5adf330`, `examples/tiny_tasks/FEATURE-REQUEST.md` TASK-1 and Request acceptance 1: the middle open task changes to `done`; the success scenario compares all original IDs, titles, positions and resulting statuses via plain `mix todo.list`, and checks the file differs only in the selected status field. The reinsert and renumber controls distinguish deleting and re-adding from updating in place.
- Addressed — Request acceptance 2: the unknown-ID scenario derives an absent ID from the seeded list, requires an unsuccessful command that names the ID and checks the original bytes and file identity/write timestamp. The silent-success and identical-rewrite controls exercise the stated counterexamples.
- Addressed — Request acceptance 3 and `examples/tiny_tasks/README.md`: both scenarios invoke actual `mix todo.complete` processes with `TODO_FILE` pointing at a fresh temporary task file that prior `mix todo.add` invocations populate. No private helper or mocked persistence stands in for the CLI.
- Preserved — `FEATURE-REQUEST.md` BASE-1 and BASE-2: the existing add and plain list behavior remains, including ID assignment, persistence, insertion order and task-line format. The existing BASE-1/BASE-2 test stays.
- Omitted deliberately — `FEATURE-REQUEST.md` TASK-2 (`mix todo.list --open`) is outside the current Request. The current Request also excludes changing the file format. The only implementation paths are the three listed above; the independent qualification example for both features is not part of this delivery.

## Tests
- Persist a selected open task as done without changing any other fields, positions or tasks: add a TASK-1 case in `examples/tiny_tasks/test/tiny_tasks_test.exs` using real `mix todo.complete`, a temporary task file and exact ordered plain-list output; the in-place completion scenario also checks the bytes on disk (scenario)
- Report an absent ID without any file write: add an unknown-ID case in `examples/tiny_tasks/test/tiny_tasks_test.exs` using a real command and temporary file; the rejection scenario checks nonzero exit, offending ID, bytes and rewrite detection (scenario)
- Preserve existing adding/listing: keep the BASE-1 and BASE-2 case in `examples/tiny_tasks/test/tiny_tasks_test.exs` (existing)

## Feasibility
- Baseline `mix test` in `examples/tiny_tasks` passed. The same probe ran `mix todo.add` and `mix todo.list` with a temporary `TODO_FILE`, confirming numeric IDs and the ordered `<id> [<status>] <title>` listing; `mix todo.complete` exited 1 with `** (Mix) The task "todo.complete" could not be found`.
- The local tools matched `.tool-versions`: Mix 1.20.4 on OTP 29 and Node 24.21.0. The Kogen runner reported Cucumber 13.3.0 and Quint 0.33.0. No external service is involved.
- The initial stderr probe included cold compile text on stdout. On warm compile, `Mix.raise` emitted a `** (Mix) ` error with the supplied ID on stderr and exited 1; the scenario does not match compiler text or require the exact error wording.
- Quint's `map` rejected lists in the first typecheck; a focused probe confirmed `replaceAt` and `length`. The final model passed typecheck and 100 sampled traces at 8 steps. It covers the ordered state transition and absent-ID no-op; the CLI/file scenarios cover diagnostics and writes.
- Scratch generation produced bounded `controls.json` overlays for the correct behavior and seven isolated defects; these are not production changes.
- Baseline `cd examples/tiny_tasks && mix format --check-formatted && mix test --warnings-as-errors` passed. Repeat for the affected subproject during Build (see `examples/tiny_tasks/README.md`).
- evidence: {"id":"completion-observer","kind":"observer","inputs":[],"observers":["features/steps/tiny-tasks-complete-command__steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/tiny-tasks-complete-command__steps.js good","exit":0,"output":"good observations accepted\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/tiny-tasks-complete-command__steps.js bad","exit":1,"output":"all bad observations rejected\n"}]}
