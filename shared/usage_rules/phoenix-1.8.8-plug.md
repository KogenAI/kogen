# phoenix - Plug Middleware

## Core Concepts

Plug is a specification for composable middleware in web applications. Plug lives at the heart of Phoenix's HTTP layer and provides an abstraction unifying the concept of a "connection" across different web server adapters. Plugs transform connections through a pipeline, enabling separation of concerns and code reuse.

The `Plug.Conn` struct represents the connection and contains request information (method, path, query parameters, headers) and response state (status, body, headers).

## Two Plug Types

### Function Plugs

Simple functions accepting a connection struct and options, then returning the modified connection:

```elixir
def introspect(conn, _opts) do
  IO.puts("Verb: #{inspect(conn.method)}")
  IO.puts("Path: #{conn.request_path}")
  conn
end
```

Use function plugs for simple, single-purpose transformations. They must return the connection to allow chaining.

### Module Plugs

Implement `init/1` and `call/2` callbacks for more complex logic with configuration:

```elixir
defmodule HelloWeb.SetLocale do
  def init(opts) do
    Keyword.fetch!(opts, :default_locale)
  end

  def call(conn, default_locale) do
    locale = conn.params["locale"] || default_locale
    Plug.Conn.assign(conn, :locale, locale)
  end
end
```

The `init/1` callback validates and prepares options at compile time (or startup in development). The `call/2` callback receives the initialized options and handles the request.

Pattern matching across multiple `call/2` heads:

```elixir
def call(conn, _opts) when conn.request_path == "/" do
  render_home(conn)
end

def call(conn, _opts) when conn.request_path == "/health" do
  Plug.Conn.send_resp(conn, 200, "OK")
end

def call(conn, _opts) do
  Plug.Conn.send_resp(conn, 404, "Not Found")
end
```

## Middleware Composition Patterns

Rather than deeply nested conditional logic, plugs enable linear pipelines using `halt(conn)` to stop further execution:

```elixir
defmodule HelloWeb.CheckAuth do
  def call(conn, _opts) do
    if logged_in?(conn) do
      conn
    else
      conn
      |> Plug.Conn.put_status(401)
      |> Plug.Conn.send_resp(401, "Unauthorized")
      |> Plug.Conn.halt()
    end
  end
end
```

## Integration Points

Plugs integrate at three levels:

### Endpoint Plugs

Execute for every request before routing. Configure in `endpoint.ex`:

```elixir
defmodule HelloWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :hello

  plug :log_request

  plug Plug.RequestId
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug HelloWeb.Router

  defp log_request(conn, _opts) do
    IO.puts("Request to #{conn.request_path}")
    conn
  end
end
```

Endpoint plugs handle global concerns: request logging, parsing, CORS, security headers.

### Router Plugs & Pipelines

Organized in pipelines, applied conditionally based on matched routes:

```elixir
defmodule HelloWeb.Router do
  use Phoenix.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :admin do
    plug HelloWeb.CheckAdmin
  end

  scope "/" do
    pipe_through :browser
    resources "/posts", PostController
  end

  scope "/" do
    pipe_through [:browser, :admin]
    resources "/admin/users", Admin.UserController
  end

  scope "/api" do
    pipe_through :api
    resources "/posts", API.PostController
  end
end
```

Pipelines execute in order. Multiple pipelines compose—`:browser` middleware runs before `:admin` middleware in the example above.

### Controller Plugs

Target specific actions using guards:

```elixir
defmodule HelloWeb.PostController do
  use HelloWeb, :controller

  plug HelloWeb.CheckAuth when action in [:edit, :update, :delete]
  plug HelloWeb.LoadPost when action in [:show, :edit, :update, :delete]

  def show(conn, _params) do
    # @post already loaded by LoadPost plug
    render(conn, :show, post: conn.assigns[:post])
  end

  def update(conn, %{"post" => params}) do
    changeset = Post.changeset(conn.assigns[:post], params)
    # ...
  end
end
```

The `plug/1` macro runs before the action. Guards filter which actions receive the plug.

## Key Transformation Functions

### Connection State

```elixir
put_status(conn, 200)
put_resp_header(conn, "cache-control", "max-age=3600")
```

### Request Information

```elixir
conn.method              # "GET", "POST", etc.
conn.request_path        # "/posts/1"
conn.query_string        # "page=2&sort=date"
conn.params              # merged parameters
conn.body_params         # POST/PUT body
conn.query_params        # query string parameters
```

### Response

```elixir
send_resp(conn, 200, "Hello")
send_file(conn, 200, path)
```

### Halt

```elixir
halt(conn)               # stops further plugs from running
```

## Best Practices

- **Single responsibility**: Each plug should handle one concern (authentication, validation, transformation).
- **Fail fast**: Use `halt(conn)` early when validation fails to avoid unnecessary processing.
- **Pipeline organization**: Group related plugs into pipelines and apply them conditionally via scopes.
- **Order matters**: Plugs execute in definition order; place dependencies-first (e.g., authentication before authorization).
- **Reusability**: Create custom module plugs for logic used across multiple routes.

---

[← Back to main](phoenix-1.8.8.md)  
**Version:** 1.8.8
