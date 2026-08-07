# plug

Plug provides a specification for composing web applications with functions and offers connection adapters for different web servers in the Erlang VM. It enables building modular web applications that work across multiple server implementations like Cowboy and Bandit. Phoenix framework utilizes Plug to manage requests, responses, and websockets.

## Quick Start

**Installation:**

```elixir
# With Cowboy (Erlang-based)
{:plug_cowboy, "~> 2.0"}

# With Bandit (Elixir-based)
{:bandit, "~> 1.0"}
```

**Basic Router:**

```elixir
defmodule AppRouter do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/hello" do
    send_resp(conn, 200, "world")
  end

  match _ do
    send_resp(conn, 404, "oops")
  end
end
```

The `:match` plug identifies matching routes; `:dispatch` executes them. Always include a catch-all `match _` handler.

## Core Concepts

### Plugs

Two varieties exist: module plugs and function plugs. Module plugs require:

- `init/1` function for option initialization
- `call/2` function accepting the connection and options, returning the modified connection

### Plug.Conn

The connection is represented as a `%Plug.Conn{}` struct containing request/response data. Connections are immutable—each manipulation returns a new connection instance rather than modifying the original.

**Request Fields**: `host`, `method`, `path_info`, `port`, `remote_ip`, `req_headers`, `scheme`, `query_string`

**Response Fields**: `resp_body`, `resp_headers`, `status`

**Fetchable Fields**: `query_params`, `body_params`, `cookies`, `session` (require explicit fetch via functions like `fetch_query_params/2` or `fetch_session/2`)

### Plug.Router

Routes are compiled into optimized lookups for excellent performance. Define routes using HTTP method macros: `get`, `post`, `put`, `patch`, `delete`, `options`, or `match` for any method.

**Route Variations:**

```elixir
get "/hello/:name" do
  send_resp(conn, 200, "hello #{name}")
end

get "/hello/*glob" do
  send_resp(conn, 200, "route after /hello: #{inspect glob}")
end

get "/hello/:name.json" do
  send_resp(conn, 200, "hello #{name}")
end

forward "/users", to: UserRouter
```

Guard clauses, glob patterns, and suffix matching are supported.

## Configuration

### Plug.Parsers (Request Body Parsing)

Insert `Plug.Parsers` between `:match` and `:dispatch` to parse request bodies only for matching routes:

```elixir
plug Plug.Parsers,
     parsers: [:urlencoded, :multipart, :json],
     pass: ["application/json"],
     length: 20_000_000,
     json_decoder: Jason
```

**Options:**

- `:parsers` - Built-in parsers (`:urlencoded`, `:multipart`, `:json`) or custom modules
- `:pass` - MIME types to bypass parsing (default `[]`)
- `:length` - Maximum request size (default 8MB)
- `:json_decoder` - Decoder module/function (e.g., `Jason`)

Parser-specific limits:

```elixir
parsers: [{:multipart, length: 20_000_000}]
```

### Plug.Session (Session Management)

```elixir
plug Plug.Session,
     store: :ets,
     key: "_my_app_session",
     table: :session,
     secure: true,
     http_only: true,
     same_site: "Strict"
```

**Required Options:**

- `:store` - Session store module (`:ets` or `:cookie`)
- `:key` - Session cookie identifier

**Cookie Security:**

- `:secure` - HTTPS-only transmission
- `:http_only` - Prevent JavaScript access
- `:same_site` - CSRF protection (`"Strict"`, `"Lax"`, `"None"`)
- `:max_age` - Expiration period

**Access Pattern:**

```elixir
conn = fetch_session(conn)
user_id = get_session(conn, :user_id)
put_session(conn, :user_id, 42)
```

Sessions are lazy—cookies only send if data is written.

### Built-in Middleware

- `Plug.BasicAuth` - Authentication
- `Plug.CSRFProtection` - CSRF protection (use with `Plug.Session`)
- `Plug.Logger` - Request logging
- `Plug.Static` - Static file serving
- `Plug.ErrorHandler` - Custom error responses
- `Plug.Debugger` - Development diagnostics

## Best Practices

### Connection Manipulation

**Assign data across plugs:**

```elixir
conn = assign(conn, :user, user_data)
merge_assigns(conn, hello: :world, foo: :bar)
```

**Header handling:**

```elixir
put_req_header(conn, "accept", "application/json")
get_req_header(conn, "content-type")  # Returns list
delete_req_header(conn, "authorization")
```

Request headers auto-lowercase; always use lowercase keys for HTTP/2 compatibility.

### Response Patterns

**Direct send:**

```elixir
send_resp(conn, 200, "Hello")
```

**Set then send:**

```elixir
conn |> resp(404, "Not found") |> send_resp()
```

**Chunked streaming:**

```elixir
conn = send_chunked(conn, 200)
{:ok, conn} = chunk(conn, "first chunk")
```

**Status codes:**

```elixir
put_status(conn, :not_found)  # 404
put_status(conn, :ok)         # 200
```

### State Management

**Assigns**: Store data for the current request only (passing between plugs).

**Sessions**: Persist across requests via cookies. Requires `fetch_session/2` before access. Use with `Plug.CSRFProtection`.

**Private**: Library-specific storage. Prefix keys with your library name to avoid conflicts.

### Pipeline Control

**Halt execution** to stop downstream plugs:

```elixir
conn |> send_resp(403, "Forbidden") |> halt()
```

**Read request body:**

```elixir
{:ok, body, conn} = read_body(conn, length: 1_000_000)
```

### Security Considerations

- Parsing untrusted data: Place `Plug.Parsers` after authentication checks
- Custom body reading: Use body readers for signature verification before parsing
- Session cookies: Always enable `:http_only` and `:secure` in production
- CSRF protection: Use `Plug.CSRFProtection` alongside `Plug.Session`

---

**Version:** 1.20.3
**Source:** [hexdocs.pm/plug](https://hexdocs.pm/plug)
**Generated:** 2026-08-07
