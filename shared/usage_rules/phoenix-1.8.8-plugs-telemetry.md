# phoenix - Plugs, Middleware, and Telemetry

## Plugs Fundamentals

Plug is the HTTP middleware specification underlying Phoenix. As the framework describes it: "a specification for composable modules in between web applications" that represents both requests and responses as a unified `Plug.Conn{}` struct.

Unlike some frameworks separating requests and responses, plugs transform a single connection object sequentially.

## Two Types of Plugs

### Function Plugs

Simple functions accepting a connection and options:

```elixir
def put_user_agent(conn, _opts) do
  put_resp_header(conn, "user-agent", "MyApp/1.0")
end

# Used in pipelines
pipeline :api do
  plug :put_user_agent
end
```

### Module Plugs

Modules implementing two functions:

```elixir
defmodule MyappWeb.AuthPlug do
  def init(opts) do
    # Initialize options (runs at compile time)
    Keyword.fetch!(opts, :realm)
  end

  def call(conn, realm) do
    # Perform the actual transformation
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> authenticate(conn, token, realm)
      _ -> send_resp(conn, 401, "Unauthorized")
    end
  end

  defp authenticate(conn, token, _realm) do
    case verify_token(token) do
      {:ok, user_id} -> assign(conn, :user_id, user_id)
      :error -> send_resp(conn, 401, "Invalid token")
    end
  end
end

# Usage
pipeline :api do
  plug MyappWeb.AuthPlug, realm: "api"
end
```

## Where Plugs Live

### 1. Endpoint Level

Apply to all requests before routing:

```elixir
# lib/myapp_web/endpoint.ex
defmodule MyappWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :myapp

  plug Plug.RequestLogger
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug MyappWeb.Router
end
```

### 2. Router Pipelines

Organize related plugs:

```elixir
defmodule MyappWeb.Router do
  use MyappWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, {MyappWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :require_auth do
    plug MyappWeb.RequireAuthPlug
  end

  scope "/", MyappWeb do
    pipe_through :browser
    get "/", PageController, :index
  end

  scope "/api", MyappWeb do
    pipe_through :api
    pipe_through :require_auth
    resources "/posts", PostController
  end
end
```

### 3. Controller-Level Plugs

Action-specific middleware:

```elixir
defmodule MyappWeb.PostController do
  use MyappWeb, :controller

  plug :require_auth when action in [:create, :update, :delete]
  plug :load_post when action in [:show, :edit, :update, :delete]

  def index(conn, _params) do
    posts = Repo.all(Post)
    render(conn, :index, posts: posts)
  end

  def show(conn, _params) do
    # @post is already loaded by the plug
    render(conn, :show, post: conn.assigns.post)
  end

  defp require_auth(conn, _opts) do
    if conn.assigns[:user_id] do
      conn
    else
      conn |> send_resp(401, "Unauthorized") |> halt()
    end
  end

  defp load_post(conn, _opts) do
    post = Repo.get!(Post, conn.params["id"])
    assign(conn, :post, post)
  end
end
```

## Halt to Stop Plug Execution

Use `halt()` to prevent subsequent plugs from running:

```elixir
def verify_admin(conn, _opts) do
  if conn.assigns[:is_admin] do
    conn
  else
    conn
    |> put_status(403)
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{error: "Forbidden"}))
    |> halt()
  end
end
```

## Common Built-in Plugs

| Plug                      | Purpose                                            |
| ------------------------- | -------------------------------------------------- |
| `Plug.Parsers`            | Parse request body (urlencoded, JSON, multipart)   |
| `Plug.MethodOverride`     | Support `_method` hidden form field for PUT/DELETE |
| `Plug.Head`               | Convert HEAD requests to GET                       |
| `Plug.Logger`             | Log requests to console                            |
| `Plug.Session`            | Session management                                 |
| `Plug.Static`             | Serve static files                                 |
| `Plug.ProtectFromForgery` | CSRF protection                                    |
| `Plug.RequestId`          | Unique request ID tracking                         |

## Telemetry Instrumentation

Phoenix includes telemetry for metrics and monitoring. New apps include a supervisor managing telemetry:

```elixir
# lib/myapp/telemetry.ex
defmodule Myapp.Telemetry do
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  def start_link(_opts) do
    children = [
      {:telemetry_poller, child_spec: Telemetry.Poller.child_spec(metrics: metrics())}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # HTTP request metrics
      Metrics.counter("http.request.count",
        description: "Total HTTP requests"
      ),
      Metrics.distribution("http.request.duration",
        unit: {:native, :millisecond},
        description: "HTTP request duration in milliseconds"
      ),

      # Database metrics
      Metrics.counter("ecto.query.total_time",
        description: "Total time spent executing queries"
      )
    ]
  end
end
```

### Emitting Custom Events

```elixir
defmodule Myapp.Worker do
  def process(id) do
    start_time = System.monotonic_time()

    # Your work
    do_work(id)

    end_time = System.monotonic_time()
    measurements = %{duration: end_time - start_time}
    metadata = %{id: id, worker: __MODULE__}

    :telemetry.execute([:myapp, :worker, :processed], measurements, metadata)
  end
end
```

### Using Telemetry Events

Reporters subscribe to telemetry events:

```elixir
# Console reporter
Telemetry.Metrics.ConsoleReporter.install()

# Store in metrics database
attach_handler = fn event, measurements, metadata, config ->
  # Send to external service (Prometheus, Datadog, etc.)
  StatsD.histogram(event, measurements.duration, tags: metadata)
end

:telemetry.attach(
  "my_handler",
  [:http, :request, :stop],
  attach_handler,
  config
)
```

## Popular Libraries Using Telemetry

Many libraries emit telemetry events automatically:

- **Ecto** — Database query metrics
- **Absinthe** — GraphQL query metrics
- **Oban** — Job queue metrics
- **LiveDashboard** — Real-time monitoring UI
- **Prometheus** — Metrics collection
- **NewRelic** — Application performance monitoring

## Transformation Pattern

Plugs follow a simple transformation pipeline:

```
Request
  ↓
┌─────────────────────────┐
│  Endpoint Plugs         │
│  - Parse body           │
│  - Add session          │
└─────────────────────────┘
  ↓
┌─────────────────────────┐
│  Router Pipelines       │
│  - Auth checks          │
│  - Load current user    │
└─────────────────────────┘
  ↓
┌─────────────────────────┐
│  Controller Plugs       │
│  - Load resource        │
│  - Verify ownership     │
└─────────────────────────┘
  ↓
┌─────────────────────────┐
│  Controller Action      │
│  - Business logic       │
│  - Render response      │
└─────────────────────────┘
  ↓
Response
```

---

[← Back to main](phoenix-1.8.8.md)  
**Version:** 1.8.8
