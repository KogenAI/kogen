# Task.Supervisor + Sandbox Allowance for Spawned Processes

**Problem**: Spawned Tasks lose access to Mox stubs and the Ecto sandbox because `Task.start` creates an unlinked process that inherits neither.
**When**: Any test spawns a Task (directly or via production code) that needs Req.Test stubs or Ecto DB access.
**See also**: `req-test-stub-external-http.md`, `elixir-async-false-triage.md`

## Solution

Use a named `Task.Supervisor` and grant explicit allowances to it from the test process.

**`application.ex`** — declare the supervisor:

```elixir
{Task.Supervisor, name: MyApp.TaskSupervisor}
```

**Production code** — use the supervisor instead of bare `Task.start`:

```elixir
Task.Supervisor.start_child(MyApp.TaskSupervisor, fn -> ... end)
```

**`data_case.ex` (or test setup)** — allow the supervisor process to use stubs and sandbox:

```elixir
Req.Test.allow(MyApp.Client, self(), fn -> Process.whereis(MyApp.TaskSupervisor) end)
Ecto.Adapters.SQL.Sandbox.allow(MyApp.Repo, self(), fn -> Process.whereis(MyApp.TaskSupervisor) end)
```

## Gotchas

`Task.start/1` leaks: the spawned process is not supervised and has no access to the test process's Mox private mode or sandbox ownership. The leak is silent — the Task silently hits the real HTTP endpoint or crashes with a sandbox ownership error rather than failing loudly in the test.

If `Req.Test.allow/3` is not viable (no hook available to pass the test PID through production code), flip the test module to `async: false` instead of modifying production code just to support the test.
