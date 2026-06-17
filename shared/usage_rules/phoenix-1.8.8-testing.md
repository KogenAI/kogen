# phoenix - Testing Strategies

## Testing Overview

Phoenix uses **ExUnit**, Elixir's built-in test framework. When you generate a new Phoenix app, it includes pre-configured test support with helper modules eliminating common boilerplate.

Run all tests:

```bash
mix test
```

## ConnCase for Controller Tests

`ConnCase` is the foundation for testing HTTP-related code:

```elixir
# test/support/conn_case.ex (auto-generated)
defmodule MyappWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import MyappWeb.ConnCase

      alias MyappWeb.Router.Helpers, as: Routes
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
```

### Writing Controller Tests

```elixir
defmodule MyappWeb.PageControllerTest do
  use MyappWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Welcome"
  end

  test "GET /users/:id", %{conn: conn} do
    user = insert(:user)
    conn = get(conn, ~p"/users/#{user.id}")
    assert response(conn, 200)
  end

  test "POST /users with valid data", %{conn: conn} do
    conn = post(conn, ~p"/users", user: %{
      name: "John",
      email: "john@example.com"
    })

    assert redirected_to(conn) == ~p"/users"
  end

  test "POST /users with invalid data", %{conn: conn} do
    conn = post(conn, ~p"/users", user: %{name: ""})
    assert html_response(conn, 200) =~ "can't be blank"
  end
end
```

### HTTP Helpers

| Helper                                     | Purpose                               |
| ------------------------------------------ | ------------------------------------- |
| `get(conn, path)`                          | Perform GET request                   |
| `post(conn, path, params)`                 | Perform POST request                  |
| `put(conn, path, params)`                  | Perform PUT request                   |
| `patch(conn, path, params)`                | Perform PATCH request                 |
| `delete(conn, path)`                       | Perform DELETE request                |
| `html_response(conn, status)`              | Assert HTML status and return body    |
| `json_response(conn, status)`              | Assert JSON status and return decoded |
| `response(conn, status)`                   | Assert status only                    |
| `redirected_to(conn)`                      | Get redirect location                 |
| `assert_error_sent(status, fn -> ... end)` | Test error handlers                   |

## DataCase for Database Tests

`DataCase` provides transaction isolation for database tests:

```elixir
# test/support/data_case.ex (auto-generated)
defmodule Myapp.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Myapp.Repo
      import Ecto
      import Ecto.Query
      import Myapp.DataCase
    end
  end

  setup :delete_and_create_sandbox
end
```

### Writing Database Tests

```elixir
defmodule Myapp.PostTest do
  use Myapp.DataCase

  alias Myapp.Post

  test "create valid post" do
    changeset = Post.changeset(%Post{}, %{
      "title" => "Hello",
      "body" => "World"
    })

    assert {:ok, post} = Repo.insert(changeset)
    assert post.title == "Hello"
  end

  test "validates required fields" do
    changeset = Post.changeset(%Post{}, %{"title" => ""})
    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset).title
  end
end

# Helper to extract errors from changeset
defp errors_on(changeset) do
  Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
    Enum.reduce(opts, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end)
end
```

## Running Tests Selectively

```bash
# By directory
mix test test/controllers/

# By file
mix test test/controllers/page_controller_test.exs

# By line number
mix test test/controllers/page_controller_test.exs:11

# By pattern
mix test --include user
```

## Using Tags for Test Organization

```elixir
defmodule MyappWeb.UserControllerTest do
  use MyappWeb.ConnCase

  @moduletag :user_tests

  @tag :slow
  test "slow test", %{conn: conn} do
    # This test takes a long time
  end

  @tag individual: "specific_test"
  test "individual test" do
    # Specific test
  end

  test "fast test" do
    # Quick test
  end
end

# Run only fast tests
mix test --exclude slow

# Run only user_tests
mix test --only user_tests

# Run specific tag value
mix test --include individual:specific_test
```

## ExUnit Features

### Setup Blocks

```elixir
defmodule Myapp.PostTest do
  use Myapp.DataCase

  setup do
    # Runs before each test
    post = insert(:post)
    {:ok, post: post}
  end

  setup :create_user  # Call setup from function

  test "something with post", %{post: post} do
    assert post.id
  end

  # Called in setup
  defp create_user(_context) do
    user = insert(:user)
    {:ok, user: user}
  end
end
```

### Assertions

```elixir
assert value == expected
refute value
assert_raise RuntimeError, fn -> Code.eval_string("raise") end

# Pattern matching
assert {:ok, post} = create_post()
refute {:error, _} = create_post()

# String matching
assert "User created" in html_response(conn, 200)
assert response(conn, 404) =~ "not found"
```

## Test Randomization and Partitioning

**Randomization** (enabled by default) ensures test isolation by running tests in random order:

```bash
# Reproduce specific seed
mix test --seed 12345

# Disable randomization
mix test --no-randomize
```

**Partitioning** enables parallel CI execution across machines:

```bash
# Machine 1
MIX_TEST_PARTITION=1/4 mix test

# Machine 2
MIX_TEST_PARTITION=2/4 mix test

# Machine 3
MIX_TEST_PARTITION=3/4 mix test

# Machine 4
MIX_TEST_PARTITION=4/4 mix test
```

## Factories with ExMachina

Install and use factories for test data:

```bash
mix ecto.gen.migration create_factories
```

```elixir
# test/factories.ex
defmodule Myapp.Factory do
  use ExMachina.Ecto, repo: Myapp.Repo

  def user_factory do
    %Myapp.User{
      name: "John Doe",
      email: sequence(:email, &"user#{&1}@example.com")
    }
  end

  def post_factory do
    %Myapp.Post{
      title: "Test Post",
      body: "Test body",
      author: build(:user)
    }
  end
end

# Usage in tests
post = insert(:post)
user = build(:user)  # Doesn't save to DB
```

## Testing Error Handlers

```elixir
test "404 not found", %{conn: conn} do
  assert_error_sent 404, fn ->
    get(conn, ~p"/nonexistent")
  end
end

test "500 internal error" do
  assert_error_sent 500, fn ->
    raise "Something went wrong"
  end
end
```

---

[← Back to main](phoenix-1.8.8.md)  
**Version:** 1.8.8
