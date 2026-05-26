# Phoenix - Testing

## Testing Framework

Phoenix uses **ExUnit**, Elixir's built-in testing framework, which emphasizes clarity and minimal magic. Tests run in random order by default for reproducibility through seed-based ordering, enabling parallel execution.

## Controller Tests with ConnCase

`ConnCase` provides integration testing infrastructure for HTTP controllers:

```elixir
defmodule MyApp.HelloControllerTest do
  use MyApp.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Welcome"
  end

  test "POST /users with valid params", %{conn: conn} do
    conn = post(conn, ~p"/users", user: %{name: "John", email: "john@example.com"})
    assert redirected_to(conn) == ~p"/users/1"
  end

  test "DELETE /users/:id", %{conn: conn} do
    user = insert(:user)
    conn = delete(conn, ~p"/users/#{user.id}")
    assert response(conn, 204)
  end
end
```

## ConnCase Setup

The `ConnCase` module automatically:

- Sets up `@endpoint` attribute pointing to your application's endpoint
- Imports `Plug.Conn` for low-level connection manipulation
- Imports `Phoenix.ConnTest` for high-level HTTP helpers
- Provides a fresh `Plug.Conn` before each test via setup block
- Enables `~p` verified routes for compile-time path generation

Define your `ConnCase`:

```elixir
defmodule MyApp.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import MyApp.ConnCase

      @endpoint MyApp.Endpoint
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
```

## HTTP Helper Functions

Common assertions for controller tests:

```elixir
# HTTP methods
get(conn, "/users")
post(conn, "/users", user: %{name: "John"})
put(conn, "/users/1", user: %{name: "Jane"})
patch(conn, "/users/1", user: %{email: "new@example.com"})
delete(conn, "/users/1")

# Response assertions
html_response(conn, 200)          # Assert 200 status, return HTML body
json_response(conn, 200)          # Assert 200 status, return JSON as map
response(conn, 204)               # Assert 204 status (no body)

# Redirects
assert redirected_to(conn) == "/users/1"
assert redirected_to(conn) == ~p"/users/1"

# Response content
assert html_response(conn, 200) =~ "User created"
assert json_response(conn, 200)["id"]
```

## View Tests

Test view rendering independently:

```elixir
defmodule MyApp.ErrorHTMLTest do
  use ExUnit.Case, async: true

  test "renders 404.html" do
    assert render_to_string(MyApp.ErrorHTML, "404", "html", []) == "Not Found"
  end

  test "renders 500.html" do
    content = render_to_string(MyApp.ErrorHTML, "500", "html", [])
    assert content =~ "Internal Server Error"
  end
end
```

Use `render_to_string/4` to test templates with assigns:

```elixir
test "renders user profile" do
  user = %{name: "John", email: "john@example.com"}
  content = render_to_string(MyApp.UserHTML, "profile", "html", user: user)
  assert content =~ "John"
  assert content =~ "john@example.com"
end
```

## Test Organization

Organize tests with modules and tags:

```elixir
defmodule MyApp.UserControllerTest do
  use MyApp.ConnCase

  describe "create" do
    test "with valid params" do
      # ...
    end

    test "with invalid params" do
      # ...
    end
  end

  describe "delete" do
    @tag :slow
    test "removes user" do
      # ...
    end
  end
end
```

Apply module-level tags:

```elixir
@moduletag :authenticated_user
@moduletag skip: "Not implemented yet"
```

## Running Tests

```bash
# Run all tests
mix test

# Run specific file
mix test test/controllers/user_controller_test.exs

# Run test at specific line
mix test test/controllers/user_controller_test.exs:23

# Run tests in directory
mix test test/controllers/

# Run with specific tag
mix test --only authenticated_user
mix test --exclude slow

# Run with seed for reproducibility
mix test --seed 12345

# Show slowest tests
mix test --slowest 10

# Watch files and rerun on change
mix test.watch
```

## Fixtures and Factories

Create test data with Ecto fixtures:

```elixir
defmodule MyApp.UserFixtures do
  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{name: "John", email: "john@example.com"})
      |> MyApp.Accounts.create_user()

    user
  end
end
```

Use in tests:

```elixir
def user_fixture do
  MyApp.UserFixtures.user_fixture()
end

test "deletes user", %{conn: conn} do
  user = user_fixture()
  conn = delete(conn, ~p"/users/#{user.id}")
  assert response(conn, 204)
end
```

## Test Partitioning for CI

Split tests across multiple machines:

```bash
# Machine 1 runs partition 1 of 4
MIX_TEST_PARTITION=1 mix test --partitions 4

# Machine 2 runs partition 2 of 4
MIX_TEST_PARTITION=2 mix test --partitions 4

# etc.
```

Each partition runs roughly 25% of tests, reducing total CI time on multi-machine infrastructure.

## Async Tests

Mark tests that don't share state as async for faster execution:

```elixir
defmodule MyApp.MessageTest do
  use ExUnit.Case, async: true

  test "formats message" do
    assert format_message("hello") == "Hello"
  end
end
```

Database-dependent tests typically can't run async due to transaction isolation. By default, `ConnCase` tests run serially; override with `async: true` for pure computation tests.

## Code Generation with Tests

Running `mix phx.gen.html` automatically generates comprehensive test files alongside the resource:

```bash
mix phx.gen.html Accounts User users name:string email:string
```

Generates `test/controllers/user_controller_test.exs` with full CRUD coverage, migrations test, and fixture helpers.

---

[← Back to main](phoenix-1.8.7.md)
**Version:** 1.8.7
