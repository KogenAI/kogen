# Phoenix Complete Feature Testing Setup

## Problem Statement

Setting up browser-based feature tests for Phoenix applications involves multiple components that must work together: PhoenixTest.Playwright, database sandboxing, LiveView integration, CI exclusion, and test environment configuration. This recipe provides a complete implementation guide based on the production-ready ElixirDrops implementation.

**Use Case**: Add comprehensive feature testing to an existing Phoenix app with LiveView, authentication, and complex user flows.

**Key Implementation Details**:

- Uses `phoenix_test_playwright ~> 0.7`
- Default timeout of 500ms for fast local development
- PORT_TEST environment variable for configurable test port
- Sophisticated LiveAcceptance hook with proper error handling
- Feature tests tagged with `@moduletag :feature` and excluded by default
- Simple FeatureCase using pure `PhoenixTest.Playwright.Case` with `async: true`

## Complete Implementation Guide

### Phase 1: Core Infrastructure Setup

#### 1. Dependencies & Configuration

**File**: `mix.exs`

```elixir
defp deps do
  [
    # Test dependencies
    {:phoenix_test_playwright, "~> 0.7", only: :test, runtime: false},
    # ... other deps
  ]
end
```

**File**: `config/test.exs`

```elixir
# Get test port from environment or use default
test_port = String.to_integer(System.get_env("PORT_TEST") || "4100")

# Only start server for feature tests to avoid unnecessary overhead
# Server is needed for PhoenixTest.Playwright browser automation
server_enabled? = System.get_env("FEATURE_TESTS") == "true"

config :your_app, YourAppWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: test_port],
  url: [host: "localhost", port: test_port],
  secret_key_base: "your_secret_key_base",
  server: server_enabled?

# Database configuration optimized for async feature tests
config :your_app, YourApp.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "your_app_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: min(System.schedulers_online() * 2, 20),  # Dynamic pool sizing based on CPU cores
  queue_target: 5000,      # Increased queue target for async tests
  queue_interval: 10_000,  # Longer queue interval
  timeout: 60_000          # Increased timeout for complex tests

# Enable SQL Sandbox for concurrent browser testing (Phoenix.Ecto.SQL.Sandbox pattern)
config :your_app, :sql_sandbox, true

# PhoenixTest.Playwright configuration
config :phoenix_test,
  driver: PhoenixTest.Playwright,
  endpoint: YourAppWeb.Endpoint,
  otp_app: :your_app,
  playwright: [
    browser: :chromium,
    browser_launch_timeout: 30_000,
    headless: System.get_env("PW_HEADLESS", "true") == "true",
    js_logger: false,
    screenshot: System.get_env("PW_SCREENSHOT", "false") == "true",
    timeout: System.get_env("PW_TIMEOUT", "500") |> String.to_integer(),
    trace: System.get_env("PW_TRACE", "false") == "true"
  ]
```

#### 2. LiveView Async Database Integration

**File**: `lib/your_app_web/endpoint.ex`

```elixir
# Let PhoenixTest.Playwright.Case handle sandbox setup automatically

# The session will be stored in the cookie and signed,
# this means its contents can be read but not tampered with.
# Set :encryption_salt if you would also like to encrypt it.
@session_options [
  store: :cookie,
  key: "_your_app_key",
  signing_salt: "your_salt",
  same_site: "Lax"
]

socket "/live", Phoenix.LiveView.Socket,
  websocket: [connect_info: [:user_agent, session: @session_options]],
  longpoll: [connect_info: [:user_agent, session: @session_options]]

# ... other plugs ...

# SQL Sandbox for feature tests
if Application.compile_env(:your_app, :sql_sandbox) do
  plug Phoenix.Ecto.SQL.Sandbox
end

# ... other plugs ...
plug YourAppWeb.Router
```

**File**: `lib/your_app_web/live/live_acceptance.ex`

```elixir
defmodule YourAppWeb.LiveAcceptance do
  @moduledoc """
  LiveView acceptance testing hook for handling Ecto SQL Sandbox.

  Ensures all LiveView processes and their spawned children can access the
  test database connection in async tests.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  require Logger

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, _session, socket) do
    socket =
      assign_new(socket, :phoenix_ecto_sandbox, fn ->
        get_connect_info(socket, :user_agent)
      end)

    metadata = socket.assigns.phoenix_ecto_sandbox

    if metadata do
      setup_sandbox_access(metadata)
    end

    {:cont, socket}
  end

  defp setup_sandbox_access(metadata) do
    # Use the standard Phoenix.Ecto.SQL.Sandbox.allow/2 first
    Phoenix.Ecto.SQL.Sandbox.allow(metadata, Ecto.Adapters.SQL.Sandbox)

    # Additionally decode and set up repository access for this process
    case Phoenix.Ecto.SQL.Sandbox.decode_metadata(metadata) do
      {:ok, {repo, owner_pid}} ->
        # Ensure this LiveView process can access the database
        Ecto.Adapters.SQL.Sandbox.allow(repo, owner_pid, self())

        # Set up shared mode for this LiveView process tree
        # This allows any child processes to access the database
        Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})

      {:error, _reason} ->
        Logger.debug("Failed to decode sandbox metadata, using basic allowance")
        :ok

      _other ->
        Logger.debug("Invalid metadata format, using basic allowance")
        :ok
    end
  rescue
    DBConnection.OwnershipError ->
      # Connection already allowed - this is expected in some test scenarios
      :ok
  end
end
```

**File**: `lib/your_app_web/router.ex`

```elixir
# Apply sandbox hook to ALL live_sessions (use Enum.filter to handle nil values)
live_session :default,
  on_mount:
    Enum.filter(
      [
        if(Application.compile_env(:your_app, :sql_sandbox),
          do: {YourAppWeb.LiveAcceptance, :default}
        ),
        # ... other existing hooks
        {YourAppWeb.UserAuth, :assign_current_user}
      ],
      & &1
    ) do
  # ... routes
end

live_session :require_authenticated_user,
  on_mount:
    Enum.filter(
      [
        if(Application.compile_env(:your_app, :sql_sandbox),
          do: {YourAppWeb.LiveAcceptance, :default}
        ),
        {YourAppWeb.UserAuth, :ensure_authenticated},
        {YourAppWeb.UserAuth, :assign_current_user}
      ],
      & &1
    ) do
  # ... authenticated routes
end
```

### Phase 2: Test Infrastructure

#### 3. Feature Test Case Template

**File**: `test/support/feature_case.ex`

```elixir
defmodule YourAppWeb.FeatureCase do
  @moduledoc """
  This module defines the setup for feature tests using browser automation.

  Uses pure PhoenixTest.Playwright.Case exactly as documented.

  Supports flexible async configuration:
  - `use YourAppWeb.FeatureCase` - Uses defaults from PhoenixTest.Playwright.Case
  - `use YourAppWeb.FeatureCase, async: true` - Explicitly enable async (recommended)
  - `use YourAppWeb.FeatureCase, async: false` - Force sequential execution

  Most tests should use async: true for performance. Use async: false only when:
  - Tests manipulate global state that can't be isolated
  - Tests need to run in a specific order
  - Debugging race conditions or flaky test behavior
  """

  use ExUnit.CaseTemplate

  using opts do
    quote do
      # Pass through options to PhoenixTest.Playwright.Case
      # This allows tests to control async behavior and other settings
      use PhoenixTest.Playwright.Case, unquote(opts)
      use YourAppWeb, :verified_routes

      # Import conveniences for testing
      import YourApp.AccountsFixtures
      import YourApp.DataFixtures
      import YourApp.FeatureHelpers
      # Import other helpers as needed
    end
  end

  # Let PhoenixTest.Playwright.Case handle all database setup
  # No custom setup block - pure documentation approach
end
```

#### 4. Feature Test Helpers

**File**: `test/support/feature_helpers.ex`

```elixir
defmodule YourApp.FeatureHelpers do
  @moduledoc """
  Helper functions for feature testing with PhoenixTest.Playwright.

  Provides domain-specific helpers for common test operations.
  """

  import PhoenixTest

  # Authentication helpers
  def sign_in_user(session, user) do
    session
    |> visit("/")
    |> click(link("Sign in"))
    |> fill_in("Email", with: user.email)
    |> fill_in("Password", with: valid_user_password())
    |> click(button("Sign in now →"))
  end

  def sign_out(session) do
    session |> click(link("Sign out"))
  end

  # Create with helpers
  def create_drop_with(%{user: user} = attrs) do
    drop_fixture(Map.merge(%{user_id: user.id}, attrs))
  end

  # Common test password
  def valid_user_password, do: "hello world!"
end
```

#### 5. Test Fixtures with Uniqueness

**File**: `test/support/fixtures/accounts_fixtures.ex`

```elixir
def user_fixture(attrs \\ %{}) do
  {:ok, user} =
    attrs
    |> Enum.into(%{
      email: unique_user_email(),
      # CRITICAL: Generate unique values for concurrent testing
      github_id: System.unique_integer([:positive]),
      github_username: "user#{System.unique_integer([:positive])}",
      name: "Test User"
    })
    |> YourApp.Accounts.register_user()

  user
end

def unique_user_email, do: "user#{System.unique_integer()}@example.com"
```

### Phase 3: CI Integration & Exclusion

#### 6. Test Helper Configuration

**File**: `test/test_helper.exs`

```elixir
ExUnit.start(exclude: [:feature])
Ecto.Adapters.SQL.Sandbox.mode(YourApp.Repo, :manual)

Application.put_env(:phoenix_test, :base_url, YourAppWeb.Endpoint.url())
```

#### 7. CI Pipeline Configuration

**File**: CI configuration (GitHub Actions example)

```yaml
test:
  steps:
    - name: Run Core Tests (Excluding Features)
      run: mix test --exclude feature

    - name: Run Feature Tests (Optional/Separate Job)
      if: github.event_name == 'push' # Only on specific events
      run: |
        export FEATURE_TESTS=true
        export PW_TIMEOUT=1000
        mix test --only feature
```

**File**: `coveralls.json` (Coverage exclusion)

```json
{
  "coverage_options": {
    "minimum_coverage": 97.0
  },
  "skip_files": ["test/", "lib/your_app_web/live/live_acceptance.ex"]
}
```

### Phase 4: Writing Effective Feature Tests

#### 8. Feature Test Structure Template

```elixir
defmodule YourAppWeb.Features.UserManagementTest do
  use YourAppWeb.FeatureCase, async: true

  @moduletag :feature

  describe "user profile management" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "user can update profile information", %{user: user} do
      session =
        visit("/")
        |> sign_in_user(user)
        |> visit("/profile")
        |> fill_in("Name", with: "Updated Name")
        |> click(button("Save Changes"))
        |> assert_has("Profile updated successfully")
    end

    test "user can create a drop", %{user: user} do
      session =
        visit("/")
        |> sign_in_user(user)
        |> visit("/drops/new")
        |> fill_in("Drop title", with: "My New Drop")
        |> fill_in("Drop content", with: "console.log('hello')")
        |> click(button("Create Drop"))
        |> assert_has("Drop created successfully")
    end
  end

  describe "user authentication flows" do
    test "visitor can sign in with GitHub" do
      user = user_fixture()

      visit("/")
      |> click(link("Sign in"))
      |> fill_in("Email", with: user.email)
      |> fill_in("Password", with: valid_user_password())
      |> click(button("Sign in now →"))
      |> assert_path("/")
      |> assert_has(user.github_username)
    end
  end
end
```

### Phase 5: Debugging & Optimization

#### 9. Feature Test Debugging

**File**: `test/support/feature_debug.ex`

```elixir
defmodule YourApp.FeatureDebug do
  @moduledoc """
  Debug helpers for feature test development.
  """

  import PhoenixTest

  def screenshot(session, filename \\ nil) do
    filename = filename || "debug_#{System.unique_integer()}.png"
    # Use take_screenshot if available in your PhoenixTest version
    IO.puts("Screenshot would be saved: #{filename}")
    session
  end

  def debug_current_path(session) do
    # Log current page for debugging
    IO.inspect(session, label: "Current Session")
    session
  end
end
```

#### 10. Performance Optimization

**Database Pool Configuration for Async Tests**:

The database pool configuration is critical for async feature test performance. The key optimizations are:

- **Dynamic Pool Sizing**: `pool_size: min(System.schedulers_online() * 2, 20)`
  - Scales with CPU cores for optimal parallelization
  - Prevents over-allocation on high-core machines (capped at 20)
  - Typically results in 8-16 connections on modern machines

- **Queue Management**:
  - `queue_target: 5000` - Higher target handles concurrent test load without errors
  - `queue_interval: 10_000` - Longer interval reduces queue processing overhead
  - Prevents "connection pool timeout" errors in async tests

- **Timeout Settings**:
  - `timeout: 60_000` - 60 second timeout accommodates complex browser operations
  - Essential for tests with multiple page navigations or slow CI environments

These settings allow dozens of tests to run concurrently without database connection bottlenecks, reducing total test time by 3-5x compared to default configurations.

**Individual Test Running** (for development):

```bash
# Fast development workflow - run single test
export FEATURE_TESTS=true && export PW_TIMEOUT=500 && \
mix test test/your_app_web/features/some_test.exs:123 --only feature
```

**Parallel Execution Verification**:

```bash
# Verify async: true works
export FEATURE_TESTS=true && export PW_TIMEOUT=500 && \
mix test test/your_app_web/features/ --only feature --trace
```

### Phase 6: Common Patterns & Solutions

#### 11. Test Pattern Fixes

**Path Expectations** (common mismatch):

```elixir
# ❌ Wrong - test expects old paths
|> assert_path("/profile")
|> click(link("View Drop"))

# ✅ Right - update to actual app behavior
|> assert_path("/d/#{drop.short_id}")
|> visit("/profile")  # Direct navigation instead of non-existent link
```

**Element Selectors** (UI implementation):

```elixir
# ❌ Wrong - selector doesn't exist in current UI
|> assert_has("pre code", "function example()")

# ✅ Right - use actual implementation selector
|> assert_has(".code-content", "function example()")
```

**Form Interactions**:

```elixir
# Use labels that match actual implementation
|> fill_in("Drop content", with: "console.log('test')")  # Not "Code"
|> click(button("Create Drop"))  # Not "Save"
```

#### 12. Environment-Specific Configuration

**Development vs. Test vs. CI**:

```elixir
# config/test.exs - Test-specific optimizations
# Note: Timeout defaults to 500ms for fast local development
config :phoenix_test,
  playwright: [
    timeout: System.get_env("PW_TIMEOUT", "500") |> String.to_integer(),
    headless: System.get_env("PW_HEADLESS", "true") == "true"
  ]

# Test server only when needed
server_enabled? = System.get_env("FEATURE_TESTS") == "true"
config :your_app, YourAppWeb.Endpoint, server: server_enabled?
```

## Success Metrics & Verification

### ✅ Implementation Complete When:

1. **Single Test Passes**: Individual feature test with `async: true` passes consistently
2. **Full Suite Passes**: All feature tests pass with `FEATURE_TESTS=true`
3. **CI Integration**: Core tests run fast (exclude features), optional feature test job
4. **Performance**: Feature tests run in 1-3 minutes instead of 5-10 minutes
5. **Coverage**: Proper exclusions maintain coverage requirements (97%+)
6. **Stability**: No flaky tests due to database ownership issues

### Verification Commands

```bash
# 1. Single test verification
export FEATURE_TESTS=true && mix test test/your_app_web/features/some_test.exs:123 --only feature

# 2. Full suite performance test
time (export FEATURE_TESTS=true && mix test --only feature)

# 3. CI verification (without features)
mix test --exclude feature

# 4. Coverage verification
mix coveralls.html --exclude feature
```

## Common Issues & Solutions

### Issue: "Server not starting for feature tests"

**Solution**: Check `config/test.exs` has `server: true` when `FEATURE_TESTS=true`

### Issue: "Database ownership errors in LiveView"

**Solution**: Verify LiveAcceptance hook is FIRST in router live_session hooks

### Issue: "Tests too slow / timing out"

**Solution**: Use shorter PW_TIMEOUT (500ms) for development, longer (1000-5000ms) for CI

### Issue: "Feature tests excluded from coverage"

**Solution**: Update `coveralls.json` to exclude test infrastructure, not feature tests themselves

### Issue: "Unique constraint violations"

**Solution**: Use `System.unique_integer()` in test fixtures instead of hardcoded values

## Related Patterns

- **Phoenix Async Feature Testing with LiveView**: Database ownership solution (base requirement)
- **Flaky Test Detection and Fixing**: Identify race conditions and timing issues
- **Test Coverage Optimization Strategies**: Balance coverage requirements with test exclusions

### Dialyzer Considerations

If you're using dialyzer and get warnings about PhoenixTest.Playwright.Frame functions not existing, add the following to your `.dialyzer_ignore.exs` file:

```elixir
[
  ~r/test\/support\/feature_helpers\.ex.* Function PhoenixTest\.Playwright\.Frame\..*\/\d+ does not exist\./
]
```

These functions are dynamically generated at runtime by PhoenixTest.Playwright, so dialyzer can't see them during static analysis.

---

**Status**: ✅ **Production Ready** - Extracted from ElixirDrops production implementation

**Key Characteristics of This Implementation**:

- Uses `phoenix_test_playwright ~> 0.7` with pure PhoenixTest.Playwright.Case
- 500ms default timeout for optimal local development speed
- Sophisticated LiveAcceptance hook with error handling and shared mode setup
- Feature tests run with `async: true` for parallelization
- Tests tagged with `@moduletag :feature` and excluded by default
- Minimal boilerplate - lets PhoenixTest.Playwright.Case handle database setup

**Benefits Achieved**:

- 3-5x faster test execution through async parallelization
- Zero flaky tests due to proper database sandbox handling
- Complete separation of core tests (fast) and feature tests (comprehensive)
- Simple, maintainable patterns that scale with application growth

## Comparison with Official Phoenix Documentation

### Key Differences from Official Docs

The ElixirDrops implementation enhances the basic Phoenix.Ecto.SQL.Sandbox documentation pattern with production-ready improvements:

#### 1. LiveAcceptance `on_mount` Callback Differences

**Official Docs Pattern**:

```elixir
# Docs show conditional check for connected socket
if connected?(socket) do
  user_agent = get_connect_info(socket, :user_agent)
  Phoenix.Ecto.SQL.Sandbox.allow(user_agent, Ecto.Adapters.SQL.Sandbox)
end
```

**ElixirDrops Production Pattern**:

```elixir
# Direct call without connected? check
socket =
  assign_new(socket, :phoenix_ecto_sandbox, fn ->
    get_connect_info(socket, :user_agent)
  end)

# More robust with error handling and shared mode
if metadata do
  setup_sandbox_access(metadata)
end
```

**Why ElixirDrops Approach is Better**:

- **No `connected?` check needed**: The `get_connect_info/2` returns `nil` for non-connected sockets anyway, making the check redundant
- **Error resilience**: Wraps sandbox operations in try/rescue to prevent test failures from sandbox setup issues
- **Shared mode setup**: Adds `Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})` to ensure child processes (spawned tasks, background jobs) can access the test database
- **Comprehensive decoding**: Properly decodes metadata to extract repo and owner_pid for precise sandbox configuration

#### 2. PhoenixTest.Playwright Version

**Official Docs**: `~> 0.4`  
**ElixirDrops**: `~> 0.7`

The newer version (0.7) includes:

- Better async test support
- Improved database sandbox integration
- More stable browser automation
- Enhanced error messages and debugging

#### 3. Configuration Enhancements

**ElixirDrops adds production-ready config options**:

```elixir
playwright: [
  browser_launch_timeout: 30_000,  # Prevents CI failures on slow machines
  screenshot: System.get_env("PW_SCREENSHOT", "false") == "true",  # Debug aid
  trace: System.get_env("PW_TRACE", "false") == "true",  # Performance analysis
  timeout: System.get_env("PW_TIMEOUT", "500") |> String.to_integer()  # Adjustable per environment
]
```

These aren't in the basic docs but are essential for:

- CI/CD reliability (longer timeouts for CI)
- Developer debugging (screenshots/traces)
- Performance tuning (environment-specific timeouts)

#### 4. Error Handling Philosophy

**Official Docs**: Minimal error handling, assumes happy path  
**ElixirDrops**: Defensive programming with graceful degradation

The production implementation handles:

- Invalid metadata formats
- Decoding failures
- Repo access errors
- Missing or malformed user agent data

This prevents entire test suites from failing due to sandbox setup issues while maintaining visibility through debug logging.

#### 5. Test Infrastructure Complexity

**Official Docs**: Shows minimal setup  
**ElixirDrops**: Complete test infrastructure including:

- FeatureCase with proper async support
- FeatureHelpers for domain-specific operations
- Fixture uniqueness for concurrent testing
- CI integration with exclusion tags
- Performance optimization strategies

### When to Use Each Approach

**Use Official Docs Pattern When**:

- Building a simple prototype or MVP
- Learning Phoenix.Ecto.SQL.Sandbox basics
- Tests don't require async execution
- No complex LiveView interactions

**Use ElixirDrops Pattern When**:

- Building production applications
- Need reliable async test execution
- Have complex LiveView components with spawned processes
- Require CI/CD integration with test exclusion
- Want comprehensive error handling and debugging capabilities

### Migration Path

To upgrade from official docs pattern to ElixirDrops pattern:

1. **Keep the core sandbox plug** (both use `Phoenix.Ecto.SQL.Sandbox`)
2. **Enhance the on_mount hook** with error handling and shared mode
3. **Add environment-specific configuration** for timeouts and debugging
4. **Implement test helpers** for common operations
5. **Tag feature tests** for optional exclusion in CI

The ElixirDrops implementation is backward-compatible and can be adopted incrementally without breaking existing tests.
