# plug

Plug is an Elixir library that defines a composable middleware specification for building request/response pipelines. It enables reusable web components that can be chained together to handle HTTP requests.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
defp deps do
  [
    {:plug, "~> 1.19.2"}
  ]
end
```

### Basic Module Plug

A module plug implements two functions:

```elixir
defmodule MyApp.LoggingPlug do
  def init(options) do
    options
  end

  def call(conn, _opts) do
    IO.puts("Request for #{conn.request_path}")
    conn
  end
end
```

### Function Plug

Simpler plugs can be functions:

```elixir
def my_plug(conn, _opts) do
  put_resp_header(conn, "x-custom", "value")
end
```

### Building a Pipeline

Use `Plug.Builder` to chain plugs:

```elixir
defmodule MyApp.Router do
  use Plug.Builder

  plug :log_request
  plug MyApp.LoggingPlug
  plug :route_handler

  defp log_request(conn, _opts) do
    IO.puts("Received: #{conn.method}")
    conn
  end

  defp route_handler(conn, _opts) do
    send_resp(conn, 200, "OK")
  end
end
```

## Core Concepts

### Two Plug Types

**Function Plugs:** Simple functions with signature `(Plug.Conn.t, opts) :: Plug.Conn.t`. Fast, minimal overhead, good for simple transformations.

**Module Plugs:** Implement the `init/1` and `call/2` callbacks. `init/1` processes configuration at compile-time and must be pure; `call/2` handles requests at runtime.

### The Connection Object

`Plug.Conn` represents an HTTP request/response lifecycle. Key fields:

- **Request data:** `method`, `path_info`, `query_string`, `request_path`, `params`
- **Response data:** `status`, `resp_headers`, `resp_body`
- **Request headers:** `req_headers` (list of tuples, lowercase keys)
- **Storage:**
  - `assigns` — request-scoped data accessible to downstream plugs
  - `private` — framework-internal data (use namespaced keys like `:my_app_foo`)

### Sending Responses

**`send_resp/3`** — Sends status and body immediately:

```elixir
send_resp(conn, 200, "Hello")
```

**`resp/3`** — Sets response without sending (useful when composing multiple plugs):

```elixir
conn
|> resp(200, "Hello")
|> send_file(path)
```

**Chunked responses** — For streaming:

```elixir
conn
|> send_chunked(200)
|> chunk("data1")
|> chunk("data2")
```

### Halting Pipeline Execution

Use `halt/1` to stop subsequent plugs and return immediately:

```elixir
defp authenticate(conn, _opts) do
  case get_session(conn, :user_id) do
    nil ->
      conn
      |> send_resp(401, "Unauthorized")
      |> halt()
    _user_id ->
      conn
  end
end
```

### Storing Request Data

**Assigns** — Store temporary data accessible to downstream plugs:

```elixir
plug :load_user

defp load_user(conn, _opts) do
  assign(conn, :current_user, user)
end

# Access in later plugs:
user = conn.assigns[:current_user]
```

**Private** — Framework-specific data using namespaced keys:

```elixir
put_private(conn, :my_app_session_id, session_id)
```

## Routing with Plug.Router

`Plug.Router` is a DSL for defining routes. It's itself a plug, so it can be nested in pipelines.

### Basic Routes

```elixir
defmodule MyApp.Router do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/hello" do
    send_resp(conn, 200, "Hello World")
  end

  post "/users" do
    send_resp(conn, 201, "User created")
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end
end
```

### Route Parameters

Dynamic segments use colons:

```elixir
get "/users/:id" do
  send_resp(conn, 200, "User #{conn.params["id"]}")
end

get "/posts/:id/comments/:comment_id" do
  send_resp(conn, 200, "Comment #{conn.params["comment_id"]}")
end
```

Use guards for validation:

```elixir
get "/users/:id" when id in ~w(1 2 3) do
  send_resp(conn, 200, "Found user")
end
```

### Globbing and Forwarding

Capture remaining path segments:

```elixir
get "/files/*glob" do
  send_resp(conn, 200, "File: #{inspect glob}")
end
```

Forward requests to another plug:

```elixir
forward "/api", to: MyApp.API
```

## Configuration

### Plug Options in init/1

Options passed to `init/1` are compile-time constants:

```elixir
defmodule MyApp.VerifyToken do
  def init(opts) do
    Keyword.fetch!(opts, :secret)  # Must be known at compile-time
  end

  def call(conn, secret) do
    token = get_req_header(conn, "authorization")
    verify(token, secret)
    conn
  end
end

# In router:
plug MyApp.VerifyToken, [secret: "my-secret"]
```

### Builder Configuration

When using `Plug.Builder`:

- **`:init_mode`** — `:compile` (default) or `:runtime` for dynamic initialization
- **`:log_on_halt`** — Log level when a plug halts (`:debug`, `:info`, etc.)
- **`:copy_opts_to_assign`** — Copy plug options to `conn.assigns`

## Headers and Cookies

### Request Headers

```elixir
get_req_header(conn, "authorization")  # Returns list

put_req_header(conn, "x-custom", "value")
merge_req_headers(conn, [{"x-id", "123"}])
```

### Response Headers

```elixir
put_resp_header(conn, "content-type", "application/json")
merge_resp_headers(conn, [{"cache-control", "no-cache"}])
```

**Important:** Always use lowercase header keys to avoid HTTP/2 duplication.

### Cookies

Set cookies:

```elixir
put_resp_cookie(conn, "session", "abc123", max_age: 3600, secure: true)
```

Retrieve cookies:

```elixir
fetch_cookies(conn)  # Parses request cookies
conn.cookies          # Maps request cookies
```

## Session and Authentication

### Basic Session Flow

```elixir
plug :load_session

defp load_session(conn, _opts) do
  fetch_session(conn)
end

# Store data:
put_session(conn, :user_id, 123)

# Retrieve data:
get_session(conn, :user_id)

# Clear:
clear_session(conn)
```

### Session Configuration

```elixir
configure_session(conn,
  renew: true,      # Force new session cookie
  drop: false,      # Keep session
  ignore: false     # Respect session configuration
)
```

## Best Practices

### 1. Pipeline Order Matters

Plugs execute top-to-bottom. Place authentication before authorization, logging before processing:

```elixir
plug :log_request          # Log first
plug MyApp.AuthenticatePlug # Then authenticate
plug MyApp.AuthorizePlug   # Then authorize
plug :handle_request       # Finally handle
```

### 2. Use Assigns for Request-Scoped Data

Never store mutable state in module variables. Use `assigns`:

```elixir
# GOOD
def require_user(conn, _opts) do
  assign(conn, :current_user, fetch_user(conn))
end

# BAD - Don't use module state
@user nil
def require_user(conn, _opts) do
  @user = fetch_user(conn)
  conn
end
```

### 3. Avoid Long-Running Operations in Plugs

Plugs should be fast. Defer heavy work to background jobs:

```elixir
# GOOD - Just schedule, don't wait
def fetch_user(conn, _opts) do
  MyApp.Worker.enqueue_user_load(user_id)
  assign(conn, :user_loading, true)
end

# BAD - Blocks response
def fetch_user(conn, _opts) do
  user = Database.expensive_query()
  assign(conn, :user, user)
end
```

### 4. Handle Errors Gracefully

Always catch exceptions in plugs:

```elixir
def protected_plug(conn, _opts) do
  try do
    process(conn)
  rescue
    error ->
      send_resp(conn, 500, "Error")
      |> halt()
  end
end
```

### 5. Use Plug.ErrorHandler for Error Pages

In development, integrate Plug.Debugger; in production, use custom error handlers:

```elixir
use Plug.ErrorHandler

def handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
  send_resp(conn, conn.status || 500, "Something went wrong")
end
```

### 6. Namespace Private Data

Avoid key collisions in `private`:

```elixir
# GOOD
put_private(conn, :my_app_user_id, 123)

# RISKY - Could collide with other plugs
put_private(conn, :user_id, 123)
```

### 7. Test Plugs in Isolation

Use `Plug.Conn.new/0` to create test connections:

```elixir
test "my_plug sets header" do
  conn = Plug.Conn.new()
  conn = MyApp.MyPlug.call(conn, MyApp.MyPlug.init([]))

  assert get_resp_header(conn, "x-custom") == ["value"]
end
```

## Common Pitfalls

### 1. Forgetting :match and :dispatch in Plug.Router

Routes won't work without these two plugs:

```elixir
# WRONG - Routes won't match
defmodule MyApp.Router do
  use Plug.Router

  get "/hello" do
    send_resp(conn, 200, "Hi")
  end
end

# CORRECT
defmodule MyApp.Router do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/hello" do
    send_resp(conn, 200, "Hi")
  end
end
```

### 2. Calling send_resp Multiple Times

Once a response is sent, subsequent sends fail silently. Use `halt/1`:

```elixir
# WRONG - Second send is ignored
send_resp(conn, 200, "First")
send_resp(conn, 200, "Second")  # Does nothing

# CORRECT
send_resp(conn, 200, "First")
|> halt()
```

### 3. Modifying Headers After send_resp

Headers must be set before sending:

```elixir
# WRONG
conn = send_resp(conn, 200, "body")
put_resp_header(conn, "x-custom", "value")  # Too late

# CORRECT
conn
|> put_resp_header("x-custom", "value")
|> send_resp(200, "body")
```

### 4. Using Runtime Values in init/1

Options must be compile-time constants:

```elixir
# WRONG - Application.get_env evaluated at compile time
plug MyApp.AuthPlug, token: Application.get_env(:my_app, :secret)

# CORRECT - Use :runtime mode
use Plug.Builder, init_mode: :runtime
plug MyApp.AuthPlug, fn _conn, _opts ->
  Application.get_env(:my_app, :secret)
end
```

### 5. Forgetting Connection is Immutable

Connections must be reassigned:

```elixir
# WRONG
put_resp_header(conn, "x-id", "123")  # Discarded
conn

# CORRECT
conn = put_resp_header(conn, "x-id", "123")
conn
```

## Version-Specific Notes (1.19.2)

- Plug 1.19.2 requires Elixir 1.11+ and OTP 21+
- HTTP/2 support is stable; lowercase header keys are enforced
- `Plug.Router` supports the full set of REST methods: `get`, `post`, `put`, `patch`, `delete`, `options`
- `send_file/5` uses OS-level sendfile when available for efficient file delivery

---

**Version:** 1.19.2
**Source:** [hexdocs.pm/plug](https://hexdocs.pm/plug/1.19.2/)
**Generated:** 2026-06-17
