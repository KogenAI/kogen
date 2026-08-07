# bandit

Bandit is a fast, standards-compliant HTTP server for Elixir Plug and Phoenix applications. Built on Thousand Island for connection management, it provides HTTP/1.x, HTTP/2, and WebSocket support with performance up to 4x faster than Cowboy. Bandit is designed to "just work" in almost all cases and has been the default server for Phoenix 1.7.11+.

## Quick Start

### Installation

Add Bandit to your `mix.exs` dependencies:

```elixir
{:bandit, "~> 1.8"}
```

### Phoenix Integration

For Phoenix applications, enable Bandit in two steps:

1. Add the dependency (above)
2. Configure in `config/config.exs`:

```elixir
config :your_app, YourAppWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"]
```

Phoenix will automatically use Bandit at startup with no additional changes needed.

### Standalone Plug Applications

For non-Phoenix Plug applications, add Bandit to your supervision tree:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Bandit, plug: MyApp.MyPlug, scheme: :http, port: 4000}
    ]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

Or start directly:

```elixir
Bandit.start_link(plug: MyApp.MyPlug, port: 4000)
```

## Core Concepts

### Connection Management

Bandit manages HTTP connections through Thousand Island, handling client connections and routing requests to your Plug or Phoenix application via standard Plug and WebSock APIs. Each request flows through your application's middleware stack.

### Supported Protocols

- **HTTP/1.1**: Full support with keepalive connections
- **HTTP/2**: Streams-based multiplexing with server push support
- **WebSockets**: Full WebSocket protocol support with optional compression

### Performance Characteristics

Bandit achieves 4x performance improvement over Cowboy in high-concurrency scenarios through optimized connection handling and non-blocking I/O patterns.

### Standards Compliance

- **h2spec**: 100% HTTP/2 specification compliance
- **Autobahn**: 100% WebSocket protocol compliance

## Configuration

### Default Settings

- **HTTP Port**: 4000
- **HTTPS Port**: 4040
- **Max Request Line**: 10,000 bytes
- **Max Headers**: 50 headers per request
- **WebSocket Frame Size**: 8MB maximum

### HTTPS Configuration

Enable HTTPS by providing certificate paths:

```elixir
{Bandit,
 plug: MyApp.MyPlug,
 scheme: :https,
 port: 4040,
 certfile: "/path/to/cert.pem",
 keyfile: "/path/to/key.pem"}
```

### HTTP/1 Options

Control HTTP/1 behavior:

```elixir
{Bandit,
 plug: MyApp.MyPlug,
 http_1_options: [
   max_request_line_size: 10000,
   max_headers: 50,
   keepalive: true,
   keepalive_timeout: 5000
 ]}
```

### HTTP/2 Options

Fine-tune HTTP/2 streams and performance:

```elixir
{Bandit,
 plug: MyApp.MyPlug,
 http_2_options: [
   max_header_block_size: 16384,
   enable_sendfile: true
 ]}
```

### Compression Options

Enable content encoding:

```elixir
{Bandit,
 plug: MyApp.MyPlug,
 compress: true}
```

Supported: zstd, gzip, deflate

### WebSocket Options

Configure WebSocket behavior:

```elixir
{Bandit,
 plug: MyApp.MyPlug,
 websocket_options: [
   max_frame_size: 8388608,
   validate_utf8: true,
   per_message_compression: true
 ]}
```

## Best Practices

### Message Handling

**CRITICAL**: Do not use `receive` patterns that match Bandit's internal messages:

- Avoid receiving `{:bandit, _}` tuples
- Avoid receiving `{:plug_conn, :sent}` tuples

Bandit relies on these messages for connection management, especially with HTTP/2. Always guard your receive patterns:

```elixir
receive do
  {:your_app, msg} -> handle_msg(msg)
  # Do NOT use generic patterns that would match Bandit internals
after
  timeout -> timeout_handler()
end
```

### Production Configuration

For production deployments:

- Use `scheme: :https` with valid certificates
- Tune `http_1_options` and `http_2_options` based on your workload
- Enable compression for text-heavy responses
- Monitor connection counts and adjust timeouts if needed

### Phoenix-Specific

No additional configuration needed beyond setting the adapter in your endpoint config. Phoenix handles Bandit integration automatically.

### Monitoring and Debugging

Bandit emits standard Plug/Phoenix logs. Monitor for:

- Connection errors (certificate issues, TLS failures)
- HTTP/2 stream resets
- WebSocket upgrade failures

---

**Version:** 1.12.4
**Source:** [hexdocs.pm/bandit](https://hexdocs.pm/bandit)
**Generated:** 2026-08-07
