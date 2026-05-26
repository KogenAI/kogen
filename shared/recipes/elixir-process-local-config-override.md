# Process-Local Config Override for Async Tests

**Problem**: `System.put_env/2` or `Application.put_env/3` in tests mutates global state and forces the whole test file to `async: false` — even one call blocks every test in that module from running concurrently.
**When**: A test needs to override a single config value (owner phone number, API base URL, feature flag) that production code reads from `Application.get_env` or `System.get_env`.
**See also**: `elixir-async-false-triage.md`, `elixir-sync-test-module-split.md`

## Solution

Read config from the process dictionary first with a `:__unset__` sentinel, fall back to `Application.get_env/2`. Tests override per-test with `Process.put/2` — ExUnit discards the process dict automatically when the test process exits.

**Production code** (`lib/combobulate/whatsapp.ex`):

```elixir
defp owner_number do
  case Process.get(:owner_whatsapp_number, :__unset__) do
    :__unset__ -> Application.get_env(:combobulate, :owner_whatsapp_number)
    value -> value
  end
end
```

**Config wiring**:

```elixir
# config/runtime.exs (guard for optional env vars)
if number = System.get_env("OWNER_WHATSAPP_NUMBER") do
  config :combobulate, :owner_whatsapp_number, number
end

# config/test.exs — explicit nil default so Application.get_env doesn't raise
config :combobulate, :owner_whatsapp_number, nil
```

**Test** — no setup, no teardown, no `on_exit`:

```elixir
test "sends alert to owner" do
  Process.put(:owner_whatsapp_number, "15559990000")
  assert {:ok, _} = Whatsapp.send_to_owner("hello")
end
```

## Why the `:__unset__` sentinel

`Process.get(:key)` returns `nil` when the key is missing — but `nil` is also a valid explicit value when the env var is not configured. The sentinel distinguishes the two:

- `:__unset__` → key was never set, fall through to `Application.get_env`
- `nil` → test explicitly set nil; production code treats this as "unconfigured" and may raise or no-op
- a string → use it

Without the sentinel, a test that wants to simulate the unconfigured state (by calling `Process.put(:owner_whatsapp_number, nil)`) would fall through to the application env instead of honoring the explicit nil.

## When this pattern breaks down

The process dict is **not inherited** across arbitrary process boundaries. If the value is consumed in a process that is not in the test's `$callers` chain (a `Task.Supervisor.start_child`-spawned task, a long-running GenServer, an Oban worker), `Process.get/1` in that process returns the default.

Options when that happens:

- Use the [`process_tree`](https://hex.pm/packages/process_tree) hex package, which walks `$ancestors` and `$callers` to find the value in any ancestor's process dict.
- Inline the manual pattern from [Andrew Dryga's gist](https://gist.github.com/AndrewDryga/b6e1e3662181afe709b575338da0cd6c).
- If neither is viable (the spawned process has no ancestor chain back to the test), fall back to `async: false` with `Application.put_env` + `on_exit` restore, or split the problematic tests into a `*SyncTest` module (see `elixir-sync-test-module-split.md`).

## What NOT to do

```elixir
# ❌ Global mutation + restore — still a race under async: true
setup do
  original = Application.get_env(:combobulate, :owner_whatsapp_number)
  Application.put_env(:combobulate, :owner_whatsapp_number, "15559990000")
  on_exit(fn -> Application.put_env(:combobulate, :owner_whatsapp_number, original) end)
  :ok
end
```

Two concurrent tests running this setup overwrite each other's values mid-flight. The `on_exit` restore runs after the other test already read the wrong value. Either use the process-local pattern or flip the file to `async: false`.

## In-repo example

- Production: `lib/combobulate/whatsapp.ex` — `send_to_owner/1` reads `owner_number/0`
- Test: `test/combobulate/conversation/handlers/support_handler_test.exs` — `Process.put(:owner_whatsapp_number, ...)` per test

## Triggers

system-put-env application-put-env process-local config-override per-test async-true process-dict sentinel unset owner-number env-var test-isolation
