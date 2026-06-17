# thousand_island

Thousand Island is a pure Elixir HTTP server library that provides a low-level foundation for building HTTP servers. It handles TCP connections, request parsing, and response delivery with minimal overhead.

## Quick Start

Add to `mix.exs`:

```elixir
def deps do
  [
    {:thousand_island, "~> 1.5.0"}
  ]
end
```

Basic server setup:

```elixir
defmodule MyApp.Handler do
  @behaviour ThousandIsland.Handler

  def handle_connection(socket, _state) do
    {:ok, socket}
  end
end

ThousandIsland.start_link(
  handler_module: MyApp.Handler,
  port: 8080
)
```

## Core Concepts

### Handler Behaviour

Implement the `ThousandIsland.Handler` behaviour to process connections:

- `handle_connection(socket, state)` — Called when client connects
- `handle_data(data, socket, state)` — Called when data arrives
- `handle_close(socket, state)` — Called on disconnect

Handlers run in separate processes, one per connection.

### Socket API

Work with raw TCP sockets via `ThousandIsland.Socket`:

```elixir
{:ok, data} = ThousandIsland.Socket.recv(socket, 0)  # Read data
:ok = ThousandIsland.Socket.send(socket, response)   # Send response
:ok = ThousandIsland.Socket.close(socket)            # Close connection
```

Use `recv(socket, 0)` to read all available data without blocking. Use a positive byte count to read exactly that many bytes.

### Supervision

Thousand Island starts via `start_link/1`, returning a supervisor PID. The supervisor manages the acceptor and connection workers.

```elixir
{:ok, _pid} = ThousandIsland.start_link(
  handler_module: MyApp.Handler,
  port: 8080
)
```

## Configuration

Pass options to `start_link/1`:

**Core Options:**

- `:handler_module` — Required. Behaviour module handling connections
- `:port` — Port number (default: 8080)
- `:ip` — Bind address tuple, e.g. `{127, 0, 0, 1}` (default: `{0, 0, 0, 0}`)

**Performance Options:**

- `:num_acceptors` — Number of acceptor processes (default: 10)
- `:backlog` — TCP listen backlog (default: 1024)

**Socket Options:**

- `:socket_options` — List of socket opts passed to `:gen_tcp.listen/2`
  - Common: `[reuseaddr: true, nodelay: true]`

**State:**

- `:handler_state` — Initial state passed to handler (default: `nil`)

Example with custom config:

```elixir
ThousandIsland.start_link(
  handler_module: MyApp.Handler,
  port: 3000,
  ip: {127, 0, 0, 1},
  num_acceptors: 20,
  socket_options: [reuseaddr: true, nodelay: true],
  handler_state: %{db: conn}
)
```

## HTTP Handling

Thousand Island does not parse HTTP; it's a raw TCP server. For HTTP:

1. Parse HTTP manually in your handler
2. Or use a higher-level library like Cowboy or Plug that wraps Thousand Island

Example raw HTTP handler:

```elixir
defmodule HTTPHandler do
  @behaviour ThousandIsland.Handler

  def handle_connection(socket, _state) do
    {:ok, socket}
  end

  def handle_data(data, socket, state) do
    case parse_http_request(data) do
      {:ok, request} ->
        response = "HTTP/1.1 200 OK\r\n\r\nHello"
        ThousandIsland.Socket.send(socket, response)
        {:close, socket, state}
      {:error, _} ->
        {:close, socket, state}
    end
  end

  def handle_close(_socket, _state) do
    :ok
  end

  defp parse_http_request(data) do
    # Implement HTTP parsing (or use plug_cowboy, etc.)
    {:ok, %{}}
  end
end
```

## Best Practices

**Connection Lifecycle:**

- Return `{:ok, socket, state}` to keep connection open
- Return `{:close, socket, state}` to close after handling
- Use pattern matching on handler returns to manage flow

**Blocking Reads:**

- `recv(socket, 0)` is non-blocking; reads buffered data
- `recv(socket, n)` blocks until n bytes available or timeout
- Avoid blocking handlers; use message passing for async work

**Error Handling:**

- Guard against malformed data in handlers
- Return `{:close, ...}` on parse errors to disconnect
- Use try-catch sparingly; let supervisor restart on crashes

**Scaling:**

- Increase `:num_acceptors` for high throughput (test both directions)
- Set reasonable socket timeouts via `:socket_options`
- Use `reuseaddr: true` to allow quick port rebinding after crashes

**Testing:**

- Write handlers as independent modules
- Test handlers directly without starting server
- Mock `ThousandIsland.Socket` for unit tests

## Common Pitfalls

**Missing `handle_close`:**
All three handler callbacks are required. Always implement `handle_close/2` even if it just returns `:ok`.

**Blocking in Handlers:**
Long operations block the connection process. Offload work to separate tasks/processes.

**State Mutation:**
Handler state is immutable. Return new state in tuple, don't modify function arguments.

**TCP Backpressure:**
Sending large responses may block. Monitor return values from `send/2`.

---

**Version:** 1.5.0  
**Source:** https://hexdocs.pm/thousand_island  
**Generated:** 2026-06-17
