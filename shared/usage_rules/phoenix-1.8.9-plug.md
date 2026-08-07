# phoenix - Plug & Middleware

## Overview

Plug lives at the heart of Phoenix's HTTP layer, serving as a specification for composable modules in web applications. Plug provides an abstraction layer for common HTTP request/response transformations, enabling clean, reusable middleware patterns without deeply nested callbacks.

Phoenix builds its entire request pipeline on top of Plug, from the endpoint level through routers and controllers. Understanding Plug is fundamental to building customized request processing pipelines.

## Two Types of Plugs

**Function Plugs** are simple functions that accept a `Plug.Conn{}` struct and options as arguments, returning a modified connection struct:

```elixir
def my_plug(conn, _opts) do
  put_resp_header(conn, "x-custom", "value")
end
```

Function plugs are lightweight and ideal for simple transformations.

**Module Plugs** require two callback functions:

`init/1` - initializes arguments and options at compile time:

```elixir
def init(opts) do
  Keyword.fetch!(opts, :key)
end
```

`call/2` - performs the actual connection transformation at runtime:

```elixir
def call(conn, key) do
  assign(conn, :api_key, key)
end
```

Module plugs enable parameterized middleware that can be composed and tested independently.

## Where Plugs Are Used

Plugs integrate at three levels:

### 1. Endpoint Level

Common plugs applied to every request before routing. The endpoint handles:

- Static file serving
- Request logging
- Session management
- CSRF protection

Define in `lib/hello_web/endpoint.ex`:

```elixir
defmodule HelloWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :hello

  plug :static
  plug Plug.RequestId
  plug Plug.Logger
  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session
  plug HelloWeb.Router
end
```

### 2. Router Level

Organized within pipelines that can be applied to route groups:

```elixir
pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :protect_from_forgery
  plug :put_user_root_layout, {HelloWeb.Layouts, :root}
end

scope "/", HelloWeb do
  pipe_through :browser
  get "/", PageController, :index
end
```

### 3. Controller Level

Applied to specific controller actions, with optional conditionals:

```elixir
defmodule HelloWeb.AdminController do
  use HelloWeb, :controller

  plug :require_admin when action in [:index, :delete]

  def require_admin(conn, _opts) do
    if conn.assigns.admin do
      conn
    else
      send_resp(conn, 403, "Forbidden")
    end
  end
end
```

## Composability and Pipeline

Plugs replace nested conditional logic with flat, reusable transformations. Using `halt(conn)` prevents subsequent plugs from executing, enabling clean error handling and authorization flows:

```elixir
defmodule HelloWeb.Plugs.Authenticate do
  def call(conn, _opts) do
    case authenticate_user(conn) do
      {:ok, user} ->
        assign(conn, :current_user, user)

      :error ->
        conn
        |> put_status(401)
        |> put_view(json: HelloWeb.ErrorJSON)
        |> render(:"401")
        |> halt()
    end
  end
end
```

Once halted, no further plugs execute. This provides a clean escape path for error conditions.

## Common Patterns

**Authentication Plug:**

```elixir
defmodule HelloWeb.Plugs.Auth do
  def call(conn, _opts) do
    if token = get_session(conn, :auth_token) do
      assign(conn, :current_user, get_user(token))
    else
      conn
    end
  end
end
```

**Rate Limiting Plug:**

```elixir
defmodule HelloWeb.Plugs.RateLimit do
  def call(conn, opts) do
    limit = Keyword.get(opts, :limit, 100)
    client = get_req_header(conn, "x-forwarded-for") |> List.first()

    if rate_ok?(client, limit) do
      conn
    else
      conn |> send_resp(429, "Too many requests") |> halt()
    end
  end
end
```

**Custom Header Plug:**

```elixir
defmodule HelloWeb.Plugs.CustomHeaders do
  def call(conn, opts) do
    headers = Keyword.get(opts, :headers, [])
    Enum.reduce(headers, conn, fn {key, value}, acc ->
      put_resp_header(acc, key, value)
    end)
  end
end
```

## Connection Transformations

The `Plug.Conn` struct represents the HTTP connection. Common transformations include:

**Reading request data:**

```elixir
conn.request_path    # "/users/123"
conn.method           # "GET"
Plug.Conn.get_req_header(conn, "accept")
Plug.Conn.fetch_query_params(conn)  # Parse query string
```

**Setting response data:**

```elixir
put_resp_header(conn, "x-custom", "value")
put_status(conn, 200)
send_resp(conn, 200, "OK")
```

**Session and assigns:**

```elixir
put_session(conn, :user_id, 123)
assign(conn, :current_user, user)
@current_user  # Available in templates via assigns
```

## Best Practices

- **Single responsibility**: Each plug should do one thing
- **Test plugs independently**: Module plugs are easy to unit test
- **Use pipeline organization**: Group related plugs in named pipelines
- **Halt early on errors**: Use `halt(conn)` to prevent unauthorized access
- **Document parameters**: Make `init/1` options clear and validated
- **Consider performance**: Plugs run on every request—optimize accordingly

---

[← Back to main](phoenix-1.8.9.md)
**Version:** 1.8.9
