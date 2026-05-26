# phoenix_ecto

Phoenix/Ecto integrates the Phoenix web framework with Ecto, Elixir's database toolkit, by implementing protocol handlers for Ecto types and exceptions. It enables seamless form handling with changesets, concurrent testing, and unified error handling.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_ecto, "~> 4.7"}
  ]
end
```

Run `mix deps.get` to fetch the dependency.

### Basic Usage with Forms

Once installed, Phoenix automatically recognizes Ecto changesets in form builders:

```elixir
<.form let={f} for={@changeset} phx-submit="save">
  <.input field={f[:name]} type="text" label="Name" />
  <.input field={f[:email]} type="email" label="Email" />
  <button type="submit">Save</button>
</.form>
```

The `@changeset` contains error information that forms automatically render without additional configuration.

## Core Concepts

### Protocol Implementations

Phoenix/Ecto provides three key protocol implementations:

1. **Phoenix.HTML.FormData** — Enables Ecto.Changeset objects to work directly with Phoenix form builders. Forms automatically extract field values, errors, and validation state from changesets.

2. **Phoenix.HTML.Safe** — Safely handles Decimal type rendering in HTML templates, preventing injection risks and ensuring proper numeric display.

3. **Plug.Exception** — Implements error handling for Ecto exceptions (e.g., `Ecto.StaleEntryError`, `Ecto.NoResultsError`), mapping them to appropriate HTTP status codes and error responses.

### SQL Sandbox for Concurrent Testing

The `Phoenix.Ecto.SQL.Sandbox` plug enables concurrent acceptance testing with headless browser drivers (Selenium, ChromeDriver) by isolating database transactions per test case.

**How it works:**

- Each test spawns in a separate database transaction
- Browser drivers run in isolated processes
- Transactions prevent test data collision
- Requires PostgreSQL (uses `ecto_sql`)

## Configuration

### Basic Setup

Enable the sandbox in `config/test.exs`:

```elixir
config :my_app, MyApp.Repo,
  pool: Ecto.Adapters.Postgres.Pool,
  pool_size: 10
```

Add the sandbox plug to your endpoint (`lib/my_app_web/endpoint.ex`), **before the router**:

```elixir
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Phoenix.Ecto.SQL.Sandbox  # <- Must be before Router
  plug MyAppWeb.Router
end
```

### Exception Handling Configuration

Exclude specific Ecto exceptions from Plug's error handling:

```elixir
config :phoenix_ecto,
  exclude_ecto_exceptions_from_plug: [Ecto.NoResultsError]
```

By default, all Ecto exceptions are handled. Exclusions bypass Plug error handling and propagate as controller errors.

### Testing Framework Integration

**With Hound** (Selenium-based):

```elixir
defmodule MyApp.FeatureTest do
  use ExUnit.Case
  hound_session()

  test "user flow" do
    navigate_to("/")
    find_element(:name, "email") |> fill_field("user@example.com")
    click({:css, "button[type=submit]"})
    assert visible_text({:class, "success"}) =~ "Saved"
  end
end
```

**With Wallaby** (WebDriver-based):

Option 1 — Auto-handled by `Wallaby.Feature`:

```elixir
defmodule MyApp.UserFlowTest do
  use Wallaby.Feature

  feature "user creates account", %{session: session} do
    session
    |> visit("/signup")
    |> fill_in(text_field("Email"), with: "user@example.com")
    |> click(button("Sign Up"))
  end
end
```

Option 2 — Manual setup (similar to Hound):

```elixir
setup do
  {:ok, _} = Application.ensure_all_started(:wallaby)
  {:ok, session} = Wallaby.start_session()
  {:ok, session: session}
end
```

## Best Practices

### 1. Changeset-Driven Forms

Always use changesets in form templates. Errors and validation state flow automatically:

```elixir
# Good: Changeset contains all error state
def create(conn, %{"user" => user_params}) do
  changeset = User.changeset(%User{}, user_params)
  case Repo.insert(changeset) do
    {:ok, user} -> redirect(conn, to: user_path(conn, :show, user))
    {:error, changeset} -> render(conn, "new.html", changeset: changeset)
  end
end
```

### 2. Transaction Isolation for Testing

Use the sandbox for integration tests, but keep unit tests lightweight:

```elixir
# Integration test (uses sandbox, runs concurrently)
defmodule MyApp.UserFlowTest do
  use ExUnit.Case
  hound_session()
  # ... browser-based tests ...
end

# Unit test (no sandbox needed)
defmodule MyApp.UserTest do
  use ExUnit.Case
  # ... repo and changeset tests ...
end
```

### 3. Error Handling in Controllers

Handle Ecto exceptions explicitly in controller actions:

```elixir
def update(conn, %{"id" => id, "user" => user_params}) do
  case Repo.get!(User, id) do
    user ->
      case Repo.update(User.changeset(user, user_params)) do
        {:ok, user} -> redirect(conn, to: user_path(conn, :show, user))
        {:error, changeset} -> render(conn, "edit.html", changeset: changeset)
      end
  rescue
    Ecto.StaleEntryError -> render_error(conn, :conflict, "Record was modified")
  end
end
```

### 4. Decimal Rendering

No manual HTML escaping needed for Decimal types—Phoenix/Ecto handles it:

```elixir
# Safe rendering: <%= @product.price %> works directly
# Renders as: <div>19.99</div>
```

### 5. Concurrent Test Setup

Always place the sandbox plug **before** the router and use a single repo configuration for all environments:

```elixir
# config/test.exs
config :my_app, MyApp.Repo,
  pool: Ecto.Adapters.Postgres.Pool,
  pool_size: 10

# lib/my_app_web/endpoint.ex
plug Phoenix.Ecto.SQL.Sandbox
plug MyAppWeb.Router
```

---

**Version:** 4.7.0
**Source:** [hexdocs.pm/phoenix_ecto](https://hexdocs.pm/phoenix_ecto/)
**Generated:** 2026-04-25
