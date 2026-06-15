# Two-Module Split for Mixed Async/Sync Tests

**Problem**: A test file has a couple of tests that genuinely must be `async: false` (e.g. they wait on a globally-named `Task.Supervisor` that races under the Ecto sandbox). Marking the whole module `async: false` serializes all sibling tests — often 20+ tests pay the serial cost when only 2 need it.
**When**: One test file has a mix of fully-async-safe tests and a small handful that touch a globally-named supervisor, singleton GenServer, or `Sandbox.mode(:shared)`.
**See also**: `elixir-async-false-triage.md`, `task-supervisor-sandbox-allowance.md`, `elixir-process-local-config-override.md`

## Solution

Keep two `defmodule` blocks in the same file — `FooTest` (`async: true`) and `FooSyncTest` (`async: false`). ExUnit discovers and runs them as independent modules: the async module runs in parallel with every other async test; the sync module runs serially on its own. Net result: only the genuinely-blocking tests pay the serial cost.

```elixir
defmodule MyAppWeb.WebhookControllerTest do
  use MyAppWeb.ConnCase, async: true

  describe "GET /api/webhook" do
    test "returns challenge for verification", %{conn: conn} do
      # GETs are safe — no spawned task, no DB write afterwards
    end
  end

  describe "POST /api/webhook — validation only" do
    test "rejects missing signature", %{conn: conn} do
      # Assertion is on the HTTP response only, no DB read after response
    end
  end
end

defmodule MyAppWeb.WebhookControllerSyncTest do
  # async: false — POST handler calls Task.Supervisor.start_child(MyApp.TaskSupervisor, …)
  # which writes to the DB. TaskSupervisor is globally-named so per-test
  # Sandbox.allow races with concurrent tests spawning their own children.
  use MyAppWeb.ConnCase, async: false

  describe "POST /api/webhook — message handling" do
    test "persists incoming message", %{conn: conn} do
      post(conn, "/api/webhook", valid_payload())
      Process.sleep(100)  # wait for spawned task
      assert Repo.aggregate(Message, :count) == 1
    end
  end
end
```

## The blocker comment is mandatory

Every `*SyncTest` module must carry a comment explaining **which specific global resource** forces `async: false` and **by what mechanism**. Without it, the next developer cleaning up test perf will flip it to async and the flake returns.

Good: `# async: false — POST handler spawns via MyApp.TaskSupervisor (globally named); per-test Sandbox.allow races under concurrency`
Bad: `# async: false for safety`

## What forces a SyncTest split

- `Task.Supervisor.start_child(GloballyNamedSup, fn -> Repo.query... end)` — the supervisor is shared across all tests, so `Sandbox.allow` for test A races with test B's concurrent allow on the same supervisor process.
- `Ecto.Adapters.SQL.Sandbox.mode(Repo, :shared)` in setup — shared mode disables per-test isolation.
- Singleton GenServer state (`MyApp.Cache`, `MyApp.RateLimiter`) that tests mutate without a reset hook.
- `Mox` with `verify_on_exit!` forcing private mode on a shared stub (see `mox-verify-on-exit-scope.md`).

## What does NOT need a SyncTest split

- `Oban.Testing` with `testing: :inline` — jobs run in the calling process, inherit sandbox ownership, safe for async.
- `Task.async/1` — inherits `$callers`, sandbox works via `Sandbox.allow(Repo, parent, self())` or the test's ownership is automatically inherited.
- `Req.Test.stub` — Req.Test is per-process by default; async-safe.
- Process-local config overrides (see `elixir-process-local-config-override.md`) — `Process.put` is discarded per test.

## Naming convention

`<ModuleName>SyncTest` lives in the same file as `<ModuleName>Test`. Do not create a separate `_sync_test.exs` file — keeping both modules in one file makes the relationship and the blocker comment discoverable together.

## In-repo example

`test/my_app_web/controllers/webhook_controller_test.exs` — `WebhookControllerTest` (async: true) alongside `WebhookControllerSyncTest` (async: false) for POST handlers that spawn via the globally-named TaskSupervisor.

## Triggers

sync-test async-false split module task-supervisor globally-named sandbox-race process-sleep db-read parallel serial single-file two-modules
