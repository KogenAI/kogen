# phoenix - Testing

## Testing Framework

Phoenix leverages **ExUnit**, Elixir's built-in testing framework, which "strives to be clear and explicit, keeping magic to a minimum." Tests are organized in the `test/` directory and mirror your source structure. Run tests with `mix test`.

## Test Cases and Helpers

Phoenix provides case modules that inject testing helpers:

**ConnCase for Controller Tests:**

```elixir
defmodule HelloWeb.UserControllerTest do
  use HelloWeb.ConnCase

  test "index returns all users", %{conn: conn} do
    user1 = insert(:user, name: "Alice")
    user2 = insert(:user, name: "Bob")

    conn = get(conn, ~p"/users")
    assert html_response(conn, 200) =~ "Alice"
    assert html_response(conn, 200) =~ "Bob"
  end

  test "show returns a user", %{conn: conn} do
    user = insert(:user, name: "Charlie")

    conn = get(conn, ~p"/users/#{user.id}")
    assert html_response(conn, 200) =~ "Charlie"
  end

  test "create creates a user", %{conn: conn} do
    conn = post(conn, ~p"/users", user: %{name: "Dave", email: "dave@example.com"})
    assert redirected_to(conn) == ~p"/users"
  end
end
```

The `ConnCase` provides:

- `conn` — A fresh connection for each test via `Phoenix.ConnTest.build_conn/0`
- `get/2`, `post/2`, `put/2`, `patch/2`, `delete/2` — HTTP verb functions
- `html_response/2`, `json_response/2` — Response assertions
- `redirected_to/1`, `redirected_to/2` — Redirect assertions

## Testing Controllers

**Testing GET requests:**

```elixir
test "show returns 404 for missing user", %{conn: conn} do
  conn = get(conn, ~p"/users/999")
  assert response(conn, 404)
end
```

**Testing POST with form data:**

```elixir
test "create handles validation errors", %{conn: conn} do
  conn = post(conn, ~p"/users", user: %{name: ""})
  assert html_response(conn, 200) =~ "can't be blank"
end
```

**Testing authentication:**

```elixir
defmodule HelloWeb.AdminControllerTest do
  use HelloWeb.ConnCase

  setup %{conn: conn} do
    {:ok, conn: conn}
  end

  test "edit requires authentication", %{conn: conn} do
    conn = get(conn, ~p"/admin/settings/edit")
    assert redirected_to(conn) == ~p"/login"
  end

  test "edit works for authenticated admins", %{conn: conn} do
    conn = conn
      |> log_in_user(build(:user, admin: true))
      |> get(~p"/admin/settings/edit")
    assert html_response(conn, 200) =~ "Edit Settings"
  end

  defp log_in_user(conn, user) do
    {:ok, _} = Auth.authenticate(user.email, user.password)

    conn
    |> init_test_session(user_id: user.id)
  end
end
```

## Testing Views and Templates

Test views by rendering templates in isolation:

```elixir
defmodule HelloWeb.UserHTMLTest do
  use HelloWeb.ConnCase
  import Phoenix.Template

  test "show renders user details" do
    user = %User{id: 1, name: "Alice", email: "alice@example.com"}

    html = render_to_string(HelloWeb.UserHTML, :show, user: user)

    assert html =~ "Alice"
    assert html =~ "alice@example.com"
  end
end
```

## Running Tests

**Full test suite:**

```bash
mix test
```

**By directory:**

```bash
mix test test/hello_web/controllers/
```

**Specific file:**

```bash
mix test test/hello_web/controllers/user_controller_test.exs
```

**Individual test by line number:**

```bash
mix test test/hello_web/controllers/user_controller_test.exs:42
```

## Test Organization and Tagging

Tag tests for selective execution:

```elixir
defmodule HelloWeb.UserControllerTest do
  use HelloWeb.ConnCase

  @moduletag :slow

  test "complex computation", %{conn: conn} do
    # slow test
  end

  @tag :admin
  test "admin-only action", %{conn: conn} do
    # test
  end
end
```

Run with filters:

```bash
mix test --only slow
mix test --exclude slow
mix test --only admin
```

## Test Parallelization

Enable parallel test execution with `async: true`:

```elixir
defmodule HelloWeb.UserControllerTest do
  use HelloWeb.ConnCase, async: true

  test "index action" do
    # test
  end
end
```

Phoenix supports distributed test partitioning via `MIX_TEST_PARTITION`:

```bash
# Run tests from partition 1 of 4 total partitions
MIX_TEST_PARTITION=1 MIX_TEST_PARTITIONS=4 mix test
```

## Reproducibility and Randomization

ExUnit randomizes test order by default to expose state-pollution issues. Reproduce a specific order using `--seed`:

```bash
mix test --seed 12345
```

This is useful for debugging non-deterministic failures.

## Code Generation for Tests

Running `mix phx.gen.html` automatically generates test files scaffolding a complete testing foundation:

```bash
mix phx.gen.html Users User users name:string email:string
```

Generates `test/hello_web/controllers/user_controller_test.exs` with tests for all CRUD operations.

---

[← Back to main](phoenix-1.8.4.md)
**Version:** 1.8.4
