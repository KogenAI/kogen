# phoenix - Testing & Quality Assurance

## Core Framework

Phoenix uses **ExUnit**, Elixir's built-in testing framework. ExUnit emphasizes clarity and explicitness, keeping magic to a minimum. Tests are written as simple functions with assertions, making test logic transparent and easy to understand.

## Running Tests

Execute tests with the `mix test` command:

```bash
mix test                                    # Run full test suite
mix test test/hello_web/controllers/        # Run specific directory
mix test test/hello_web/controllers/page_controller_test.exs  # Single file
mix test test/hello_web/controllers/page_controller_test.exs:42  # Single test by line
```

## Test Structure

Phoenix generates test files with real examples for reference. A basic controller test follows this pattern:

```elixir
defmodule HelloWeb.PageControllerTest do
  use HelloWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Welcome"
  end
end
```

Every test receives a fresh connection via the `conn` fixture, established by ConnCase setup.

## ConnCase Module

ConnCase provides testing utilities by:

- Setting the endpoint for testing
- Importing connection helpers from `Plug.Conn` and `Phoenix.ConnTest`
- Establishing a fresh connection via `setup` blocks before each test

Use ConnCase for all controller and integration tests:

```elixir
use HelloWeb.ConnCase
```

## HTTP Helpers

CommonHelpers provided by Phoenix.ConnTest:

```elixir
get(conn, ~p"/posts")           # GET request
post(conn, ~p"/posts", post: %{})  # POST with params
put(conn, ~p"/posts/1", post: %{})   # PUT request
patch(conn, ~p"/posts/1", post: %{})  # PATCH request
delete(conn, ~p"/posts/1")      # DELETE request
```

## Assertions

Verify responses with these helpers:

**HTML responses:**

```elixir
assert html_response(conn, 200) =~ "Post created"
assert html_response(conn, 200) =~ ~r/data-status="active"/
```

**JSON responses:**

```elixir
assert json_response(conn, 200) == %{"id" => 1, "title" => "Post"}
assert json_response(conn, 422)["errors"]["title"] != nil
```

**Status codes:**

```elixir
assert conn.status == 200
assert redirected_to(conn) == ~p"/posts/1"
```

**Flash messages:**

```elixir
assert get_flash(conn, :info) == "Post created"
```

## Test Organization

Use tags to organize and filter tests:

**Module-level tags:**

```elixir
@moduletag :slow
@moduletag :integration
```

**Test-level tags:**

```elixir
@tag :skip
test "expensive operation" do
  # ...
end

@tag timeout: 1000
test "fast endpoint" do
  # ...
end
```

**Run filtered tests:**

```bash
mix test --only slow              # Run @tag :slow tests
mix test --exclude integration    # Skip @tag :integration
```

## Randomization

Tests run in random order by default, improving test isolation and catching order dependencies:

```bash
mix test --seed 401472      # Reproduce with specific seed
mix test --no-randomize     # Run tests in file order (not recommended)
```

Random execution catches tests that depend on other tests running first—a common source of flaky tests.

## Generators

Phoenix provides code generators that create tests automatically:

```bash
mix phx.gen.html Posts Post posts title:string body:text
```

This generates controller tests, view tests, and context tests alongside your resources.

## Testing Patterns

**Setup helpers for common state:**

```elixir
setup do
  user = create_user()
  {:ok, user: user}
end

test "requires authentication", %{user: user} do
  # user is available
end
```

**Fixtures for test data:**

```elixir
defp create_user(_) do
  {:ok, user} = Accounts.create_user(%{email: "test@example.com"})
  user
end
```

**Testing error cases:**

```elixir
test "returns error when title is blank" do
  conn = post(conn, ~p"/posts", post: %{"title" => ""})
  assert html_response(conn, 200) =~ "can't be blank"
end
```

## LiveView Testing

Test LiveViews with `Phoenix.LiveViewTest`:

```elixir
use HelloWeb.ConnCase
import Phoenix.LiveViewTest

test "increments counter", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/counter")

  assert has_element?(view, "p", "Counter: 0")

  view |> element("button", "+") |> render_click()

  assert has_element?(view, "p", "Counter: 1")
end
```

Test event handling:

```elixir
test "filters posts", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/posts")

  view |> form("form", %{query: "test"}) |> render_change()

  assert has_element?(view, "li", "Test Post")
end
```

## Concurrency

Run tests in parallel across CI machines:

```bash
MIX_TEST_PARTITION=1/3 mix test    # Run 1/3 of tests
MIX_TEST_PARTITION=2/3 mix test    # Run 2/3 of tests
MIX_TEST_PARTITION=3/3 mix test    # Run 3/3 of tests
```

This partitioning speeds up CI pipelines by distributing tests across multiple jobs.

## Best Practices

- **Test behavior, not implementation**: Assert on responses, not internal state
- **Use verified routes**: Always use `~p"/path"` in tests to catch broken routes early
- **Keep tests isolated**: Don't rely on shared state between tests
- **Test happy and sad paths**: Test both success and error cases
- **Avoid test flakiness**: Don't test timing-dependent behavior
- **Organize by feature**: Group related tests in same file or module
- **Use descriptive names**: Test names should explain what they verify

---

[← Back to main](phoenix-1.8.9.md)
**Version:** 1.8.9
