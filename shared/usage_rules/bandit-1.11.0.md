# Bandit

Bandit is an HTTP server for Plug and WebSock applications, written entirely in Elixir and built on the Thousand Island networking foundation. It supports HTTP/1.x, HTTP/2, and WebSocket protocols over both HTTP and HTTPS connections, prioritizing correctness (100% compliance on h2spec and Autobahn test suites), clarity in infrastructure code, and performance (up to 4x faster than Cowboy for HTTP/1.x).

## Quick Start

### For Phoenix Applications

1. Add dependency: `{:bandit, "~> 1.8"}`
2. Update `config/config.exs` with: `adapter: Bandit.PhoenixAdapter`
3. Start your application—no other changes needed

### For Plug Applications

Launch via supervisor in `lib/my_app/application.ex`:

```elixir
children = [{Bandit, plug: MyApp.MyPlug}]
Supervisor.start_link(children, opts)
```

Or directly call `Bandit.start_link(plug: MyPlug)`.

## Core Concepts

**Protocol Support**: Bandit provides complete server support for HTTP/1.x as defined in RFC 9112, alongside HTTP/2 and WebSocket capabilities.

**WebSocket Integration**: Works seamlessly with Phoenix 1.7+ for channels and LiveView without additional configuration.

**Compression**: Supports gzip and deflate encoding across HTTP versions for efficient data transfer.

**Drop-in Replacement**: Designed as a compatible alternative to Cowboy in Plug/Phoenix applications.

## Configuration

### Basic HTTP Configuration

```elixir
{Bandit, plug: MyApp.MyPlug}
```

### HTTPS Setup

```elixir
{Bandit,
 plug: MyApp.MyPlug,
 scheme: :https,
 certfile: "/absolute/path/to/cert.pem",
 keyfile: "/absolute/path/to/key.pem"}
```

### Common Options

- `port`: HTTP listen port (default: 4000)
- `ip`: Listen address (default: `{127, 0, 0, 1}`)
- `scheme`: `:http` or `:https`
- `certfile`: Path to SSL certificate (HTTPS only)
- `keyfile`: Path to SSL private key (HTTPS only)

## Best Practices

**Message Matching**: Never receive messages matching `{:bandit, _}` or `{:plug_conn, :sent}` within Plug processes, as Bandit uses these internally for protocol management.

**Connection Handling**: Bandit handles HTTP keep-alive, pipelining, and protocol upgrade (WebSocket) transparently. No special Plug-level code required.

**Performance**: Bandit demonstrates significant throughput advantages while maintaining comparable memory efficiency to competing servers. Use for high-concurrency workloads.

**SSL/TLS**: Provide absolute paths to certificate and key files; relative paths may cause loading failures in production.

**Monitoring**: Bandit integrates with Telemetry. Monitor key events: `:bandit` span events for request lifecycle tracking.

---

**Version:** 1.11.0
**Source:** [hexdocs.pm/bandit](https://hexdocs.pm/bandit/)
**Generated:** 2026-05-09
