# bandit

Bandit is an Elixir-based HTTP server designed for Plug and WebSock applications. It emphasizes correctness, clarity, and performance as fundamental goals and serves as the default HTTP server for Phoenix framework versions 1.7.11 and later.

## Quick Start

### Phoenix Integration

1. Add to `mix.exs`: `{:bandit, "~> 1.8"}`
2. Update `config/config.exs` with: `adapter: Bandit.PhoenixAdapter`
3. Restart your application
4. WebSocket support is automatically enabled on Phoenix 1.7+

### Standalone Plug Application

```elixir
Bandit.start_link(plug: MyPlug)
```

### HTTPS Configuration

Provide scheme, certfile, and keyfile parameters when starting the server. Use absolute paths or relative paths with the `otp_app` parameter.

## Core Concepts

### Protocol Support

- **HTTP/1.x, HTTP/2, and WebSocket** protocols with full compliance
- Both HTTP and HTTPS connections
- Content encoding compression (gzip, deflate, zstd)
- Per-message WebSocket compression

### Performance Characteristics

- HTTP/1.x up to 4x faster than Cowboy
- HTTP/2 up to 1.5x faster than Cowboy
- 100% compliance on h2spec HTTP/2 tests
- 100% compliance on Autobahn WebSocket tests

### Connection Management

Bandit manages client connections via Thousand Island (underlying connection handler) and serves as minimal "glue" between socket management and application code.

## Configuration

### Essential Parameters

- `plug` (required): Specifies the Plug handler
- `scheme`: `:http` or `:https` (default: `:http`)
- `port`: TCP listening port (default: 4000 for HTTP, 4040 for HTTPS)
- `ip`: Interface binding—supports IPv4/IPv6 tuples, `:loopback`, `:any`, or Unix sockets

### Compression & Response Control

- `compress`: Enable response compression via content-encoding (default: true)
- `response_encodings`: Preferred compression order—specify list like `[:zstd, :gzip, :x-gzip, :deflate]`

### Logging & Diagnostics

- `startup_log`: Controls startup logging level (default: `:info`, set false to disable)
- `log_protocol_errors`: Set to `:short`, `:verbose`, or false
- `log_client_closures`: Controls connection closure logging (default: false)

### HTTP/1 Options

- `max_request_line_length`: 10,000 bytes default
- `max_header_count`: 50 headers default
- `max_requests`: Connection request limit (0 = unlimited)
- `clear_process_dict`: Clears non-internal process dictionary entries between requests (default: true)

### HTTP/2 Options

- `max_header_block_size`: 50,000 bytes default
- `max_reset_stream_rate`: Rate limiting for RST_STREAM frames to prevent abuse

## Best Practices

### Process Safety

**Critical:** Never receive messages matching `{:bandit, _}` or `{:plug_conn, :sent}` in your code—Bandit uses these internally, especially for HTTP/2 requests. Guard all receive calls with pattern matches that exclude these tuples.

```elixir
# ❌ Unsafe
receive do
  msg -> handle_msg(msg)
end

# ✅ Safe
receive do
  {:custom, data} -> handle_data(data)
  :timeout -> handle_timeout()
end
```

### Startup & Supervision

- Start Bandit via supervisor in your application tree, not directly in IEx
- For Phoenix, let the endpoint configuration manage startup via `Bandit.PhoenixAdapter`
- Specify `otp_app` when using relative paths for HTTPS certificates

### Memory & Resource Management

- Use `clear_process_dict` to avoid accumulating request state across connections
- Monitor `max_header_count` and `max_request_line_length` if handling untrusted clients
- Set `max_requests` on HTTP/1 connections if memory leaks are suspected in long-lived connections

### Compression Strategy

- Enable `compress` for most applications (default behavior)
- Configure `response_encodings` to match client capabilities if serving specific client types
- zstd provides better compression ratios but requires client support; gzip is widely compatible

### Logging for Production

- Keep `startup_log` at `:info` for visibility into port and scheme binding
- Set `log_protocol_errors` to `:short` in production to catch misconfigured clients without spam
- Disable `log_client_closures` in high-traffic deployments to reduce log volume

---

**Version:** 1.10.3
**Source:** [hexdocs.pm/bandit](https://hexdocs.pm/bandit/)
**Generated:** 2026-04-25
