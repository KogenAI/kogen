# phoenix - Plugs & Middleware

## What is Plug?

Plug is a specification for composable modules in web applications, serving as an abstraction layer for different web servers. It provides a unified concept of a "connection" (`Plug.Conn`) that gets transformed throughout the request lifecycle. Unlike other frameworks with deeply nested callbacks, Plug enables flat, composable chains of middleware.

## Two Types of Plugs

**Function Plugs:**

Simple functions that accept a `Plug.Conn` struct and options, then return a modified connection:

```elixir
defmodule HelloWeb.Plugs.Introspect do
  def introspect(conn, _opts) do
    IO.puts("Verb: #{inspect(conn.method)}")
    IO.puts("Path: #{conn.request_path}")
    conn
  end
end

# Usage in router
scope "/" do
  pipe_through {:introspect, []}
end
```

**Module Plugs:**

Modules implementing two callbacks—`init/1` for compile-time initialization and `call/2` for the actual connection transformation:

```elixir
defmodule HelloWeb.Plugs.Locale do
  def init(default), do: default

  def call(%Plug.Conn{params: %{"locale" => loc}} = conn, _)
      when loc in ["en", "fr", "de"] do
    assign(conn, :locale, loc)
  end

  def call(conn, default) do
    assign(conn, :locale, default)
  end
end

# Usage in router
pipeline :browser do
  plug HelloWeb.Plugs.Locale, "en"
end
```

## Plug Composition Across Layers

Plugs operate at three levels:

**Endpoint (global):**

Applied to every request before routing:

```elixir
defmodule HelloWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :hello

  plug :log_request_id
  plug Plug.Static, at: "/", from: :hello, gzip: false, only: ~w(css fonts images js favicon.ico robots.txt)
  plug Plug.RequestLogger
  plug :dispatch

  defp log_request_id(conn, _opts) do
    request_id = :crypto.strong_rand_bytes(8) |> Base.encode16()
    assign(conn, :request_id, request_id)
  end
end
```

**Router (scoped):**

Grouped into pipelines for specific route families:

```elixir
pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_live_flash
  plug :put_root_layout, html: {HelloWeb.Layouts, :root}
  plug :protect_from_forgery
  plug :put_secure_browser_headers
end

pipeline :api do
  plug :accepts, ["json"]
end

scope "/", HelloWeb do
  pipe_through :browser
  get "/", PageController, :index
end

scope "/api", HelloWeb do
  pipe_through :api
  get "/users", UserController, :index
end
```

**Controller (per-action):**

Applied to specific actions with optional guards:

```elixir
defmodule HelloWeb.UserController do
  use HelloWeb, :controller

  plug :require_login when action in [:edit, :update, :delete]
  plug :check_ownership when action in [:edit, :update, :delete]

  def edit(conn, %{"id" => id}) do
    user = conn.assigns.user
    render(conn, :edit, user: user)
  end

  defp require_login(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn |> redirect(to: ~p"/login") |> halt()
    end
  end

  defp check_ownership(conn, _opts) do
    user = conn.assigns.user
    if user.id == conn.assigns.current_user.id do
      conn
    else
      conn |> put_status(403) |> halt()
    end
  end
end
```

## Building Custom Plugs

A custom authentication plug:

```elixir
defmodule HelloWeb.Plugs.Auth do
  import Plug.Conn

  def init(opts) do
    Keyword.fetch!(opts, :secret)
  end

  def call(conn, secret) do
    token = get_session(conn, :auth_token)

    case verify_token(token, secret) do
      {:ok, user_id} ->
        assign(conn, :current_user_id, user_id)
      :error ->
        conn
    end
  end

  defp verify_token(nil, _), do: :error
  defp verify_token(token, secret) do
    # Token verification logic
    {:ok, 42}  # user_id
  end
end

# Usage
pipeline :authenticated do
  plug HelloWeb.Plugs.Auth, secret: "my-secret-key"
end
```

## Halting the Plug Pipeline

Use `halt/1` to stop subsequent plugs from executing:

```elixir
defmodule HelloWeb.Plugs.RequireAdmin do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.assigns[:is_admin] do
      conn
    else
      conn
      |> put_status(403)
      |> put_resp_header("content-type", "application/json")
      |> send_resp(403, ~s({"error": "Admin access required"}))
      |> halt()
    end
  end
end
```

When `halt/1` is called, no further plugs in the pipeline execute.

## Common Built-in Plugs

Phoenix includes essential plugs for common tasks:

- `Plug.Static` — Serve static files
- `Plug.RequestLogger` — Log requests
- `Plug.Session` — Session management
- `Plug.CSRF` — CSRF protection (`:protect_from_forgery`)
- `Plug.SSL` — Force HTTPS in production
- `Plug.Head` — Handle HEAD requests

## Avoiding Nested Callbacks

Plugs solve the "callback hell" problem through composition. Instead of:

```elixir
# ❌ Nested callbacks - hard to read
def authenticate_request(conn, _opts) do
  case get_header(conn, "authorization") do
    nil ->
      send_error(conn, 401)
    token ->
      case verify_token(token) do
        {:ok, user} ->
          case load_user_permissions(user) do
            permissions ->
              assign(conn, :user, user)
              |> assign(:permissions, permissions)
            error ->
              send_error(conn, 500)
          end
        :error ->
          send_error(conn, 401)
      end
  end
end
```

Use flat plug pipelines:

```elixir
# ✅ Flat, composable plugs
pipeline :authenticated do
  plug HelloWeb.Plugs.Auth
  plug HelloWeb.Plugs.LoadUser
  plug HelloWeb.Plugs.LoadPermissions
end

scope "/api", HelloWeb.Api do
  pipe_through :authenticated
  get "/dashboard", DashboardController, :show
end
```

---

[← Back to main](phoenix-1.8.4.md)
**Version:** 1.8.4
