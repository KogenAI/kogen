# websock_adapter

WebSockAdapter provides Plug-based WebSocket upgrade support for Elixir applications, enabling seamless conversion of HTTP connections to WebSocket connections while maintaining compatibility with multiple HTTP servers.

## Quick Start

### Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:websock_adapter, "~> 0.6.0"}
  ]
end
```

### Basic Usage

Upgrade an HTTP connection to WebSocket using the `upgrade/4` function:

```elixir
WebSockAdapter.upgrade(conn, MyWebSocketHandler, initial_state, opts)
```

Components:

- `conn`: Plug connection
- `MyWebSocketHandler`: Module implementing WebSocket handler behavior
- `initial_state`: State passed to handler's `init/1` callback
- `opts`: Configuration options

## Core Concepts

### Handler Module

Implement a handler module with required callbacks:

- `init(state)` — Initialize handler and return `{:ok, state}`
- `handle_in({data, opcode}, state)` — Process incoming frames
- `handle_info(message, state)` — Handle internal messages
- `terminate(reason, state)` — Cleanup

### Message Types

Handlers work with frames identified by opcode:

- `:text` — Text frames (UTF-8 validated by default)
- `:binary` — Binary frames
- `:ping` / `:pong` — Control frames
- `:close` — Connection close frames

### Connection Upgrade

The `upgrade/4` call:

1. Validates the WebSocket upgrade request (when `early_validate_upgrade: true`)
2. Converts the Plug connection to a WebSocket
3. Delegates frame handling to your handler module

## Configuration

Set options in the `opts` parameter passed to `upgrade/4`:

**Validation & Safety:**

- `early_validate_upgrade` (boolean, default: `true`) — Validate upgrade request before returning; catch malformed requests within Plug lifecycle
- `validate_utf8` (boolean, default: `true`) — Verify text and close frame payloads are valid UTF-8

**Performance Tuning:**

- `timeout` (ms, default: 60000) — Idle connection timeout
- `max_frame_size` (octets, default: 10MB) — Maximum frame size limit
- `active_n` (integer) — Cowboy-specific: packet request batching for throughput optimization
- `fullsweep_after` (integer) — Garbage collection frequency (OTP 24+)
- `max_heap_size` (integer) — Process heap size limit

**Protocol Features:**

- `compress` (boolean, default: `false`) — Enable WebSocket compression negotiation
- `deflate_options` (keyword) — Fine-tune compression behavior

Example configuration:

```elixir
opts = [
  timeout: 120000,
  max_frame_size: 5_242_880,
  validate_utf8: true,
  compress: true
]

WebSockAdapter.upgrade(conn, handler, state, opts)
```

## Best Practices

1. **Enable Early Validation** — Keep `early_validate_upgrade: true` (default) to catch malformed requests within the Plug lifecycle rather than deferring to server-level processing
2. **Set Frame Size Limits** — Configure `max_frame_size` based on expected message patterns to prevent memory exhaustion
3. **Resource Constraints** — Set `max_heap_size` limits appropriate to your application's expected WebSocket usage
4. **UTF-8 Validation** — Use `validate_utf8: true` (default) for text frames unless raw bytes are required; disable only if performance is critical
5. **Compression Tuning** — Enable `compress` only when bandwidth is a constraint; compression adds CPU overhead and heap pressure
6. **Server-Specific Optimization** — When using Cowboy, tune `active_n` to balance throughput against memory consumption

---

**Version:** 0.6.0
**Source:** [hexdocs.pm/websock_adapter](https://hexdocs.pm/websock_adapter/0.6.0)
**Generated:** 2026-08-07
