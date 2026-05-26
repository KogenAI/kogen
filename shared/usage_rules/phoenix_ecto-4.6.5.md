# phoenix_ecto

Phoenix Ecto integrates Phoenix with Ecto and implements protocols that make it easier to use Ecto with Phoenix when working with HTML or JSON. It provides seamless interoperability between Phoenix and Ecto across different data formats.

## Quick Start

**Installation**: Add to `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_ecto, "~> 4.6"}
  ]
end
```

**Application setup**: No special configuration required for basic usage. The library is automatically started as an application dependency.

## Core Concepts

### Protocol Implementations

Phoenix Ecto implements key protocols for framework integration:

- **Phoenix.HTML.FormData** for Ecto.Changeset — enables seamless form building with changesets
- **Phoenix.HTML.Safe** for Decimal — allows Decimal types in Phoenix templates without casting
- **Plug.Exception** for Ecto exceptions — proper HTTP error handling for constraint and validation failures

### SQL Sandbox for Testing

Phoenix.Ecto.SQL.Sandbox enables concurrent acceptance tests with Ecto's SQL sandbox, supporting:

- Headless browser testing (Chromium, Firefox)
- LiveView testing
- Channel testing
- External HTTP client testing

## Configuration

### Enable SQL Sandbox for Tests

In `config/test.exs`:

```elixir
config :your_app, sql_sandbox: true
```

Add the plug to your endpoint stack (must be early, before authentication):

```elixir
if Application.compile_env(:your_app, :sql_sandbox) do
  plug Phoenix.Ecto.SQL.Sandbox
end
```

### Acceptance Test Setup

Checkout a sandboxed connection in test setup:

```elixir
setup tags do
  pid = Ecto.Adapters.SQL.Sandbox.start_owner!(YourApp.Repo, shared: not tags[:async])
  metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(YourApp.Repo, pid)

  {:ok, repo: YourApp.Repo, sandbox_metadata: metadata}
end
```

### LiveView Testing

Use an `on_mount/4` hook to assign and allow sandbox access:

```elixir
def on_mount(:sandbox_setup, _params, _session, socket) do
  Phoenix.Ecto.SQL.Sandbox.allow(socket.assigns.phoenix_ecto_sandbox, Ecto.Adapters.SQL.Sandbox)
  {:cont, socket}
end
```

### Channel Testing

Configure socket to accept connect info:

```elixir
socket "/socket", YourApp.UserSocket, websocket: [connect_info: [:user_agent]]
```

In channel `join/3`, call `allow/2`:

```elixir
Phoenix.Ecto.SQL.Sandbox.allow(socket.assigns.phoenix_ecto_sandbox, Ecto.Adapters.SQL.Sandbox)
```

### External Client Testing

For remote HTTP clients (Playwright, Cypress):

```elixir
plug Phoenix.Ecto.SQL.Sandbox,
  at: "/sandbox",
  repo: MyApp.Repo,
  timeout: 15_000
```

Clients POST to `/sandbox` to create sessions and DELETE to stop them, passing sandbox metadata via headers.

## Best Practices

### Concurrent Testing

- Use `shared: not tags[:async]` for async tests — enables true concurrent execution
- Place SQL Sandbox plug early in middleware stack — before authentication/authorization
- Always call `allow/2` before accessing database in channels/LiveViews

### Error Handling

Phoenix Ecto automatically converts Ecto exceptions to proper HTTP responses:

- Unique constraint violations → 400 Bad Request
- Foreign key violations → 422 Unprocessable Entity
- Validation errors → 422 with changeset details

### Form Handling

Use changesets directly in templates — Phoenix.HTML.FormData protocol handles conversion:

```elixir
<%= form_for @changeset, Routes.user_path(@conn, :create), fn f -> %>
  <%= text_input f, :email %>
  <%= submit "Create" %>
<% end %>
```

### Decimal in Templates

Decimal values render correctly without manual casting:

```elixir
<%= @product.price %>  <!-- renders as string, Phoenix.HTML.Safe protocol handles it -->
```

### Testing Patterns

- For async tests: use `:async` tag with `shared: false` in sandbox setup
- For sequential tests: omit `:async` tag with `shared: true`
- Always cleanup: Sandbox automatically rolls back after each test
- External clients: implement proper header handling for metadata passing

---

**Version:** 4.6.5
**Source:** [hexdocs.pm/phoenix_ecto](https://hexdocs.pm/phoenix_ecto/)
**Generated:** 2025-10-28
