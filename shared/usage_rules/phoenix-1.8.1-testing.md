# Phoenix 1.8.1 - Testing Patterns & Best Practices

## Core Framework

Phoenix leverages **ExUnit**, Elixir's built-in testing framework, which "strives to be clear and explicit, keeping magic to a minimum." The framework generates test modules with real-world examples automatically when creating new resources. Tests provide explicit, maintainable verification of application behavior.

## ConnCase Pattern

Test modules use `use HelloWeb.ConnCase` rather than raw ExUnit. This case template injects testing utilities including `Plug.Conn` helpers and `Phoenix.ConnTest`, providing a pre-built connection object through the `setup` block.

```elixir
defmodule HelloWeb.PostControllerTest do
  use HelloWeb.ConnCase

  setup do
    user = insert(:user)
    {:ok, user: user}
  end

  test "GET /posts lists all posts", %{conn: conn} do
    post1 = insert(:post, title: "First Post")
    post2 = insert(:post, title: "Second Post")

    conn = get(conn, ~p"/posts")

    assert response(conn, 200) =~ "First Post"
    assert response(conn, 200) =~ "Second Post"
  end

  test "POST /posts creates a new post", %{conn: conn, user: user} do
    post_attrs = %{
      "title" => "New Post",
      "body" => "Content here",
      "user_id" => user.id
    }

    conn = post(conn, ~p"/posts", post: post_attrs)

    assert redirected_to(conn) == ~p"/posts"
    assert Repo.get_by(Post, title: "New Post")
  end

  test "GET /posts/:id shows post detail", %{conn: conn} do
    post = insert(:post, title: "Test Post")

    conn = get(conn, ~p"/posts/#{post}")

    assert response(conn, 200) =~ "Test Post"
  end

  test "returns 404 for nonexistent post", %{conn: conn} do
    conn = get(conn, ~p"/posts/999999")
    assert response(conn, 404)
  end
end
```

## Assertion Structure

Tests combine multiple assertions in single statements using pattern matching:

```elixir
# Check status, content type, and response body
conn = get(conn, ~p"/users")
assert response(conn, 200) =~ "username"

# Verify status and header
conn = post(conn, ~p"/users", user: attrs)
assert response(conn, 201)
assert get_resp_header(conn, "location")

# Multiple assertions
conn = get(conn, ~p"/posts/#{post.id}")
response = response(conn, 200)
assert response =~ post.title
assert response =~ post.body
refute response =~ "draft"
```

## Test Execution

Run tests at various scopes:

```bash
# Full test suite
mix test

# Specific directory
mix test test/hello_web/controllers/

# Specific file
mix test test/hello_web/controllers/post_controller_test.exs

# Specific test by line number
mix test test/hello_web/controllers/post_controller_test.exs:42

# Watch mode (requires `mix test.watch` package)
mix test.watch
```

## Tag-Based Test Management

Mark tests with tags for selective execution:

```elixir
defmodule HelloWeb.PostControllerTest do
  use HelloWeb.ConnCase

  @moduletag :slow
  @tag slow: true

  test "slow operation", %{conn: conn} do
    # Expensive test
  end

  @tag skip: "Waiting for API integration"
  test "integration with external service" do
    # Skipped
  end
end
```

Execute tests selectively:

```bash
# Run only slow tests
mix test --only slow

# Run except slow tests
mix test --exclude slow

# Run only integration tests
mix test --only integration

# Configure defaults in test_helper.exs
ExUnit.start(exclude: :slow)
```

## Test Randomization

ExUnit randomizes test execution order by default using a seed value:

```bash
# Reproduce a failing test sequence
mix test --seed 401472

# Disable randomization
mix test --no-randomize
```

Randomization catches dependencies between tests that should be isolated. Always ensure tests pass regardless of execution order.

## Parallel Test Execution

Tests marked `async: true` run concurrently:

```elixir
@tag async: true
test "concurrent safe operation" do
  # This test runs in parallel with others
end
```

For CI environments, ExUnit supports partitioning across machines using `MIX_TEST_PARTITION`:

```bash
# Machine 1: Run first third of tests
MIX_TEST_PARTITION=1/3 mix test

# Machine 2: Run second third
MIX_TEST_PARTITION=2/3 mix test

# Machine 3: Run final third
MIX_TEST_PARTITION=3/3 mix test
```

Each partition maintains its own test database, enabling parallelization across CI nodes.

## Testing Patterns

**Setup blocks** provide fixtures:

```elixir
setup %{conn: conn} do
  user = insert(:user, name: "Test User")
  post = insert(:post, user: user)
  {:ok, user: user, post: post}
end
```

**Controller tests** verify behavior:

```elixir
test "JSON response", %{conn: conn} do
  post = insert(:post)
  conn = get(conn, ~p"/api/posts/#{post.id}")

  assert json_response(conn, 200) == %{
    "id" => post.id,
    "title" => post.title
  }
end
```

**Async safety** - use database transactions:

```elixir
@tag async: true
test "database operations" do
  # Each async test runs in its own transaction
  post = insert(:post)
  assert Repo.get(Post, post.id)
end
```

## Common Test Utilities

- `get(conn, path)` - Simulate GET request
- `post(conn, path, params)` - Simulate POST request
- `put(conn, path, params)` - Simulate PUT request
- `patch(conn, path, params)` - Simulate PATCH request
- `delete(conn, path)` - Simulate DELETE request
- `response(conn, status)` - Get response body
- `json_response(conn, status)` - Parse JSON response
- `html_response(conn, status)` - Get HTML response
- `redirected_to(conn)` - Get redirect location
- `get_resp_header(conn, name)` - Get response header

## Best Practices

- Write tests with the ConnCase pattern for HTTP testing
- Tag tests to enable selective execution
- Use setup blocks for common fixtures
- Test both happy path and error cases
- Verify status codes, redirects, and response content
- Run full test suite before committing
- Use `async: true` for independent tests
- Provide meaningful test names describing behavior
- Test at the controller/integration level for most features
- Use randomized execution to catch test dependencies
- Keep test databases separate with partitioning

---

[← Back to main](phoenix-1.8.1.md)
**Version:** 1.8.1
