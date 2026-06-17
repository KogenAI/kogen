# bandit

Bandit is a minimalist HTTP server for Elixir applications using Plug and WebSock APIs. It serves as middleware between client connections and application code, with intentional simplicity so it "just works" in most scenarios without extensive configuration.

## Quick Start

### Phoenix Integration (Recommended)

Add to `mix.exs`:

```elixir
{:bandit, "~> 1.12.0"}
```

Configure in `config/config.exs`:

```elixir
config :your_app, YourAppWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter
```

After restarting, the startup message will indicate Bandit is serving your application.

### Standalone Plug Applications

Start Bandit through your supervision tree:

```elixir
{Bandit, plug: MyApp.MyPlug}
```

Or directly:

```elixir
Bandit.start_link(plug: MyPlug)
```

## Core Concepts

### Minimal API Philosophy

Bandit deliberately maintains a minimal API surface. Configure what you need; most deployments require no extra configuration beyond enabling the adapter.

### Protocol Support

- **HTTP/1.1**: Full support with configurable options
- **HTTP/2**: Available with configurable settings per protocol version
- **WebSockets**: Full WebSocket support through WebSock and WebSockAdapter libraries. Phoenix applications (1.7+) handle this automatically for Channels and LiveView.

### HTTPS Support

Enable HTTPS with three required options:

```elixir
config :your_app, YourAppWeb.Endpoint,
  https: [
    ip: {0, 0, 0, 0},
    port: 443,
    certfile: "/path/to/certfile.pem",
    keyfile: "/path/to/keyfile.pem",
    scheme: :https
  ]
```

## Configuration

### Phoenix Endpoint Configuration

Place detailed options in environment-specific files like `config/dev.exs`:

```elixir
config :your_app, YourAppWeb.Endpoint,
  http: [
    ip: {127, 0, 0, 1},
    port: 4000,
    thousand_island_options: [num_acceptors: 123],
    http_options: [log_protocol_errors: false],
    websocket_options: [compress: false]
  ]
```

### Configuration Keys

- **`:ip`** – Bind address (tuple format: `{0, 0, 0, 0}` for all interfaces)
- **`:port`** – Server port
- **`:scheme`** – Set to `:https` for HTTPS
- **`:certfile`** – Path to SSL certificate (required for HTTPS)
- **`:keyfile`** – Path to SSL private key (required for HTTPS)
- **`:thousand_island_options`** – Transport layer options (e.g., `num_acceptors`)
- **`:http_options`** – HTTP/1.1-specific settings (e.g., `log_protocol_errors`)
- **`:websocket_options`** – WebSocket settings (e.g., `compress`)

### Compression

Built-in HTTP response compression supports:

- zstd
- gzip
- deflate

Compression is negotiated via HTTP Accept-Encoding headers.

### Phoenix Adapter Helper Functions

Get the Bandit server process for a scheme:

```elixir
Bandit.PhoenixAdapter.bandit_pid(YourAppWeb.Endpoint, :http)
```

Get bound address and port:

```elixir
Bandit.PhoenixAdapter.server_info(YourAppWeb.Endpoint, :http)
```

## Best Practices

### 1. Message Handling in Plug Processes

**CRITICAL WARNING**: Do not let your Plug code receive messages matching these patterns:

```elixir
{:bandit, _}
{:plug_conn, :sent}
```

These are reserved for internal Bandit messaging. Receiving them can cause interference with the server's internal communication. Use `receive` guards carefully or avoid message matching altogether in Plug modules.

### 2. Environment-Specific Configuration

Use separate configuration files for each environment:

- `config/dev.exs` – Development settings with detailed logging
- `config/test.exs` – Test environment with minimal overhead
- `config/prod.exs` – Production settings with optimized performance

### 3. WebSocket Configuration (Phoenix)

- Requires Phoenix 1.7+ for native LiveView and Channel support
- Configure WebSocket options only if defaults don't meet requirements
- Most projects need no additional WebSocket configuration

### 4. HTTPS in Production

- Always provide absolute paths to certificate and key files
- Use environment variables or runtime configuration for secrets
- Test HTTPS configuration in a staging environment first

### 5. Performance Tuning

Adjust `thousand_island_options` for high-concurrency workloads:

```elixir
thousand_island_options: [
  num_acceptors: 32,  # Increase for high connection rates
  transport_options: [
    backlog: 1024      # Pending connection queue size
  ]
]
```

### 6. Minimal Configuration Philosophy

Start with defaults and add configuration only when testing reveals a need. Bandit is designed to perform well without extensive tuning.

## Common Pitfalls

### 1. Message Pattern Interference

Wrapping Plug code in `receive` blocks that match `{:bandit, _}` or `{:plug_conn, :sent}` will break the server. Refactor to avoid these patterns or use selective message receivers.

### 2. Incorrect HTTPS Setup

Missing `certfile` or `keyfile` with `scheme: :https` will cause startup failure. Always provide both when enabling HTTPS.

### 3. Binding to Wrong Interface

`ip: {0, 0, 0, 0}` binds to all interfaces (includes 0.0.0.0). Use `ip: {127, 0, 0, 1}` for localhost-only binding in development.

### 4. WebSocket in Phoenix < 1.7

WebSocket support requires Phoenix 1.7 or later for full feature integration. Earlier versions may require manual WebSocket configuration.

### 5. Certificate Path Issues

Always use absolute paths for `certfile` and `keyfile` in production. Relative paths may fail if the working directory changes.

---

**Version:** 1.12.0
**Source:** [hexdocs.pm/bandit](https://hexdocs.pm/bandit/1.12.0)
**Generated:** 2026-06-17
