# bandit

Bandit is an HTTP web server for Elixir applications that connects client connections with application code via the Plug and WebSock APIs. It provides high-performance HTTP/1 and HTTP/2 support with built-in Phoenix framework compatibility.

## Quick Start

### Installation

Add to your project dependencies in `mix.exs`:

```elixir
{:bandit, "~> 1.0"}
```

### Phoenix Integration

For Phoenix 1.7+ projects, add one line to your endpoint configuration in `config/config.exs`:

```elixir
config :my_app, MyAppWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter
```

Restart your Phoenix server—Bandit handles the rest automatically.

### Standalone Plug Applications

For non-Phoenix Plug apps, start Bandit via supervisor or direct call:

```elixir
Bandit.start_link(
  plug: MyPlug,
  port: 4000,
  ip: {127, 0, 0, 1}
)
```

## Core Concepts

### Protocol Support

- **HTTP/1**: Full support with configurable request line limits, header limits, and keepalive request counts
- **HTTP/2**: Header block size and connection request maximization
- **WebSockets**: Automatic support in Phoenix; direct integration via WebSock and WebSockAdapter libraries
- **HTTPS/SSL**: Configure via certificate and key file paths

### Connection Architecture

Bandit connects client connections using Thousand Island for transport-layer handling, then passes requests through HTTP protocol handlers (HTTP/1 or HTTP/2) to your Plug application.

### Message Safety

**CRITICAL**: Guard against receiving internal Bandit messages in Plug processes:

- Never match on `{:bandit, _}` patterns
- Never match on `{:plug_conn, :sent}` patterns

These messages are reserved for Bandit's internal server operations.

## Configuration

### Environment-Specific Settings

Place configuration in environment-specific files for different behavior:

```elixir
# config/dev.exs
config :my_app, MyAppWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [port: 4000, ip: {127, 0, 0, 1}]

# config/prod.exs
config :my_app, MyAppWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  https: [port: 443, keyfile: "/path/to/key", certfile: "/path/to/cert"],
  force_ssl: [rewrite_on: [:x_forwarded_proto]]
```

### Key Configuration Parameters

**Connection Settings**

- `port` - Server port (default: 4000 for HTTP, 4040 for HTTPS)
- `ip` - IP address binding (default: all interfaces)

**HTTP/1 Options** (nested under `http:` or `https:`)

- `max_request_line_length` - Limit for request line size
- `max_header_value_length` - Individual header size limit
- `max_requests_per_connection` - Keepalive request count

**HTTP/2 Options**

- `max_header_block_size` - Header block size limit
- `max_requests_per_connection` - Connection request maximum

**Logging Settings**

- `log_protocol_errors` - Control protocol error logging (default: true)
- `log_exception_threshold` - Minimum severity for exception logging

## Best Practices

1. **Minimal Configuration**: Standard Phoenix projects typically need only the adapter line. Existing configurations usually work unchanged.

2. **Protocol Tuning**: Set HTTP/1 and HTTP/2 limits based on your client profiles. Stricter limits improve security; higher limits support larger requests.

3. **HTTPS Deployment**: Use `force_ssl` for production to redirect HTTP to HTTPS automatically.

4. **Server Inspection**: Use helper functions to access running server details programmatically:
   - `bandit_pid/2` - Get server process ID
   - `server_info/2` - Access server configuration and statistics

5. **Production Hardening**:
   - Verify certificate paths exist before deployment
   - Test protocol error logging thresholds in staging
   - Monitor connection limits under expected load

6. **WebSocket Configuration**: Phoenix handles WebSocket setup automatically. For custom WebSocket behavior, consult Bandit's WebSockAdapter integration patterns.

7. **Dependency Clarity**: Always pin to `~> 1.0` or specific versions rather than floating dependencies in production environments.

---

**Version:** 1.8.0
**Source:** [hexdocs.pm/bandit](https://hexdocs.pm/bandit)
**Generated:** 2025-10-28
