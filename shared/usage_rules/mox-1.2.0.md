# mox

Mox is an Elixir library for defining concurrent mocks based on behavioral contracts. It prioritizes explicit contracts and pattern matching over complex expectation rules, enabling safe concurrent testing with clear mock semantics.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
defp deps do
  [{:mox, "~> 1.2", only: :test}]
end
```

### Basic Usage

1. Define a behavior contract:

```elixir
defmodule MyApp.MyBehaviour do
  @callback fetch(String.t()) :: {:ok, term()} | {:error, term()}
  @callback store(String.t(), term()) :: :ok
end
```

2. Create a mock in `test_helper.exs`:

```elixir
Mox.defmock(MyApp.MyMock, for: MyApp.MyBehaviour)
```

3. Set expectations in tests:

```elixir
test "fetches data" do
  MyApp.MyMock
  |> expect(:fetch, fn id -> {:ok, data} end)

  assert MyApp.MyMock.fetch("123") == {:ok, data}
end
```

## Core Concepts

### Behaviors (Contracts)

Mocks must implement defined behaviors. This provides compile-time guarantees and prevents mocking undefined functions. Define using `@callback` macros.

### Three Mock Modes

**expect/4** - Function must be called exactly n times with specified arguments:

```elixir
expect(mock, :function_name, n, fn args -> result end)
```

Raises error if expectations not met or if called with unexpected arguments.

**stub/3** - Function can be called zero or many times:

```elixir
stub(mock, :function_name, fn args -> result end)
```

Flexible for optional or variable-call scenarios.

**deny/3** - Function must never be called:

```elixir
deny(mock, :function_name)
```

Asserts a function is not invoked during test execution.

### Verification

- `verify!/0` - Verifies all expectations in current process
- `verify!/1` - Verifies expectations for specific mock module
- `verify_on_exit!/1` - Auto-verifies when test exits (recommended for async tests)

## Configuration

### Private vs Global Mode

**Private Mode (default)** - Each process has isolated expectations:

```elixir
set_mox_private()  # Add to test_helper.exs
```

Enables `async: true` testing. Recommended for most cases.

**Global Mode** - Expectations shared across processes:

```elixir
set_mox_global()  # Add to test_helper.exs
```

Required for integration tests with spawned processes. Forces `async: false`.

### Child Process Access

Allow child processes to access parent's expectations:

```elixir
setup do
  MyApp.MyMock |> allow(self(), fn -> ... end)
  :ok
end
```

### Stub with Implementation

Replace all behavior functions with a module implementation:

```elixir
stub_with(MyApp.MyMock, MyApp.MyImplementation)
```

Useful for reusing real implementations in tests.

## Best Practices

### Pattern Matching Over Assertions

Use function clauses to match on arguments:

```elixir
# Good - explicit pattern matching
expect(mock, :fetch, fn
  "valid_id" -> {:ok, data}
  "invalid_id" -> {:error, :not_found}
end)

# Less ideal - complex assertions inside function
expect(mock, :fetch, fn id ->
  if id == "valid_id", do: {:ok, data}, else: {:error, :not_found}
end)
```

### Define Mocks at Compile Time

Create mocks in `test_helper.exs`, not per-test:

```elixir
# test_helper.exs
Mox.defmock(MyApp.MyMock, for: MyApp.MyBehaviour)
ExUnit.start()

# ❌ Avoid in individual test files
# defmock should not be scattered across tests
```

### Use verify_on_exit! for Async Tests

Automatically verify when test completes:

```elixir
setup do
  MyApp.MyMock |> verify_on_exit!()
  :ok
end
```

### Combine expect and stub Strategically

- Use `expect` for critical calls that must happen
- Use `stub` for optional fallback behavior
- Use `deny` to prevent unwanted side effects

### Keep Mocks Simple

Avoid complex logic in mock implementations. If a mock becomes complicated, it may indicate the contract is unclear or the implementation needs testing differently.

### Test Behavior, Not Implementation

Mock at behavior boundaries, not internal function calls:

```elixir
# Good - mock external service behavior
defmock(HTTPClientMock, for: HTTPClient)

# Avoid - mocking internal functions
defmock(InternalHelperMock, for: InternalHelper)
```

---

**Version:** 1.2.0
**Source:** [hexdocs.pm/mox](https://hexdocs.pm/mox/)
**Generated:** 2026-04-25
