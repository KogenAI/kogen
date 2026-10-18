# Feature request: complete a task and list open work

Please extend Tiny Tasks so that a task can be completed without losing the
rest of the list.

- **BASE-1:** Adding a task assigns the next numeric ID and persists it for
  later commands.
- **BASE-2:** Plain `mix todo.list` shows every task in insertion order, one per
  line as `<id> [<status>] <title>`, using `open` for the current status.
- **TASK-1:** Add `mix todo.complete ID`. It changes the identified task from
  open to done while preserving every task's ID, title, insertion position, and
  status otherwise. A task line uses `done` for a completed task.
- **TASK-2:** Add `mix todo.list --open`. It prints every open task, and no done
  task, in insertion order using the same task-line format. Plain
  `mix todo.list` continues to show all tasks.

You may choose the exact success confirmation shown after a task is completed.
