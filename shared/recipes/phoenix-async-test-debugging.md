# Phoenix Async Testing Troubleshooting Guide

## Problem Statement

When enabling `async: true` for Phoenix feature tests with PhoenixTest.Playwright, you may encounter `DBConnection.OwnershipError` even after following the official documentation. This guide provides debugging strategies and solutions based on real-world troubleshooting.

## Common Error Pattern

```
** (DBConnection.OwnershipError) cannot find ownership process for #PID<0.xxx.0>
```

This error typically occurs in LiveView hooks that perform database queries during mount.

## Critical Bug: The `connected?(socket)` Trap

### ❌ THE BUG (Prevents async tests from working)

```elixir
defmodule YourAppWeb.LiveAcceptance do
  def on_mount(:default, _params, _session, socket) do
    socket =
      assign_new(socket, :phoenix_ecto_sandbox, fn ->
        # WRONG! This causes metadata to be nil during initial page load
        if connected?(socket), do: get_connect_info(socket, :user_agent)
      end)

    # metadata will be nil, sandbox.allow fails silently
    metadata = socket.assigns.phoenix_ecto_sandbox
    # ...
  end
end
```

### ✅ THE FIX

```elixir
defmodule YourAppWeb.LiveAcceptance do
  def on_mount(:default, _params, _session, socket) do
    socket =
      assign_new(socket, :phoenix_ecto_sandbox, fn ->
        # RIGHT! Get User-Agent in both dead and live view phases
        get_connect_info(socket, :user_agent)
      end)

    # metadata will contain sandbox info from PhoenixTest.Playwright
    metadata = socket.assigns.phoenix_ecto_sandbox
    # ...
  end
end
```

**Why this matters**:

- PhoenixTest.Playwright correctly encodes sandbox metadata in User-Agent headers
- The metadata is available in BOTH dead view (initial HTTP) and live view (websocket) phases
- Using `connected?(socket)` prevents reading metadata during the critical initial page load
- Without metadata during initial mount, database queries fail immediately

## Debugging Strategy

### Step 1: Add Comprehensive Logging

```elixir
defmodule YourAppWeb.LiveAcceptance do
  require Logger

  def on_mount(:default, _params, _session, socket) do
    # Debug what phase we're in
    Logger.debug("LiveAcceptance hook - Connected: #{connected?(socket)}")

    socket =
      assign_new(socket, :phoenix_ecto_sandbox, fn ->
        user_agent = get_connect_info(socket, :user_agent)
        Logger.debug("User-Agent metadata: #{inspect(user_agent)}")
        user_agent
      end)

    metadata = socket.assigns.phoenix_ecto_sandbox
    Logger.debug("Sandbox metadata assigned: #{inspect(metadata)}")

    if metadata do
      Logger.debug("Calling Phoenix.Ecto.SQL.Sandbox.allow")
      Phoenix.Ecto.SQL.Sandbox.allow(metadata, Ecto.Adapters.SQL.Sandbox)
    else
      Logger.warning("No sandbox metadata available!")
    end

    {:cont, socket}
  end
end
```

### Step 2: Test Command for Debugging

```bash
# Run single test with verbose output
FEATURE_TESTS=true PORT_TEST=4101 mix test test/your_app_web/features/your_test.exs:86 --include feature --trace
```

Environment variables explained:

- `FEATURE_TESTS=true` - Enables Phoenix server for browser tests
- `PORT_TEST=4101` - Custom port to avoid conflicts
- `--include feature` - Runs tests tagged with `@moduletag :feature`
- `--trace` - Shows detailed test execution

### Step 3: Verify Hook Execution Order

Ensure LiveAcceptance runs BEFORE any hooks that query the database:

```elixir
# In your LiveView module
defmodule YourAppWeb.SomeLive do
  use YourAppWeb, :live_view

  # LiveAcceptance MUST come first
  on_mount {YourAppWeb.LiveAcceptance, :default}
  on_mount {YourAppWeb.NavbarSearchHook, :default}  # This queries DB
  on_mount {YourAppWeb.UserAuth, :mount_current_user}

  # ...
end
```

Or globally in router:

```elixir
live_session :default,
  on_mount: [
    # FIRST - Database access setup
    {YourAppWeb.LiveAcceptance, :default},
    # THEN - Hooks that need database
    {YourAppWeb.NavbarSearchHook, :default},
    {YourAppWeb.UserAuth, :mount_current_user}
  ] do
  # routes...
end
```

### Step 4: Verify PhoenixTest.Playwright Metadata Encoding

If metadata is still nil, verify the version and configuration:

```elixir
# mix.exs - Ensure you have the right version
{:phoenix_test_playwright, "~> 0.7", only: :test, runtime: false}
```

```bash
# Recompile dependency after any changes
MIX_ENV=test mix deps.compile phoenix_test_playwright
```

## Working Implementation Reference

### Dependencies (mix.exs)

```elixir
{:phoenix_test_playwright, "~> 0.7", only: :test, runtime: false}
```

### Test Configuration (config/test.exs)

```elixir
config :your_app, :sql_sandbox, true

# PhoenixTest.Playwright with reasonable timeouts
config :phoenix_test,
  driver: PhoenixTest.Playwright,
  endpoint: YourAppWeb.Endpoint,
  otp_app: :your_app,
  playwright: [
    browser: :chromium,
    timeout: String.to_integer(System.get_env("PW_TIMEOUT", "500")),
    headless: System.get_env("PW_HEADLESS", "true") == "true"
  ]
```

### Complete LiveAcceptance Hook

```elixir
defmodule YourAppWeb.LiveAcceptance do
  @moduledoc """
  Enables async database testing for LiveView feature tests.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  def on_mount(:default, _params, _session, socket) do
    socket =
      assign_new(socket, :phoenix_ecto_sandbox, fn ->
        # CRITICAL: No connected? check here!
        get_connect_info(socket, :user_agent)
      end)

    metadata = socket.assigns.phoenix_ecto_sandbox

    if metadata do
      Phoenix.Ecto.SQL.Sandbox.allow(metadata, Ecto.Adapters.SQL.Sandbox)
    end

    {:cont, socket}
  end
end
```

### Simple FeatureCase

```elixir
defmodule YourAppWeb.FeatureCase do
  use ExUnit.CaseTemplate

  using opts do
    quote do
      # PhoenixTest.Playwright.Case handles all sandbox setup
      use PhoenixTest.Playwright.Case, unquote(opts)
      use YourAppWeb, :verified_routes

      import YourApp.AccountsFixtures
      import PhoenixTest
    end
  end
end
```

## Testing Async Behavior

### Verify Single Test

```bash
FEATURE_TESTS=true mix test test/your_app_web/features/visitor_browsing_test.exs --include feature
```

### Run All Feature Tests in Parallel

```bash
FEATURE_TESTS=true mix test --only feature
```

### Performance Comparison

```bash
# Sequential (async: false)
time FEATURE_TESTS=true mix test --only feature

# Parallel (async: true) - Should be 3-5x faster
time FEATURE_TESTS=true mix test --only feature
```

## Reference Implementation

StoryDeck at `/Users/almirsarajcic/Areas/StoryDeck/story_deck` has working async browser tests that can serve as a reference implementation.

## Key Takeaways

1. **PhoenixTest.Playwright works correctly** - It properly encodes sandbox metadata in User-Agent headers
2. **The Phoenix.Ecto.SQL.Sandbox documentation is accurate** - Follow it exactly
3. **The `connected?(socket)` bug is subtle but critical** - It prevents metadata from being read during initial page load
4. **Hook order matters** - LiveAcceptance must run before any database-querying hooks
5. **Use environment variables for debugging** - `FEATURE_TESTS`, `PORT_TEST`, `PW_TIMEOUT` help isolate issues
6. **The solution is simpler than expected** - No need for complex shared mode switching or custom sandbox handling

## Contribution Opportunity

If you encounter a library that doesn't support async database testing (unlike PhoenixTest.Playwright which does), consider contributing the User-Agent metadata passing mechanism that enables this pattern.

---

**Status**: ✅ **Debugging Guide Complete** - Based on real troubleshooting of ElixirDrops async feature tests
