# remote_ip

RemoteIp is an Elixir plug that rewrites a connection's remote IP address based on HTTP forwarding headers. It processes generic comma-separated headers (`X-Forwarded-For`, `X-Real-Ip`, `X-Client-Ip`) and RFC 7239 compliant `Forwarded` headers, with built-in protection against IP spoofing through last-to-first IP processing and configurable proxy/client whitelists.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [{:remote_ip, "~> 1.2"}]
end
```

### Basic Usage

Add RemoteIp to your Plug pipeline **before** `:match` and `:dispatch`:

```elixir
defmodule MyApp do
  use Plug.Router

  plug RemoteIp
  plug :match
  plug :dispatch
end
```

Outside a Plug pipeline, use `RemoteIp.from/2`:

```elixir
RemoteIp.from([{"x-forwarded-for", "1.2.3.4"}])
# Returns: {1, 2, 3, 4}

RemoteIp.from(headers, headers: ~w[x-custom-header])
```

## Core Concepts

**IP Extraction Strategy:** RemoteIp processes IPs last-to-first to prevent spoofing. Loopback and private IP ranges are ignored by default (127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, IPv6 unique local).

**Header Formats Supported:**

- `Forwarded` (RFC 7239): `Forwarded: for=192.0.2.60;proto=https`
- Generic comma-separated: `X-Forwarded-For: 192.0.2.60, 192.0.2.61`
- Multiple headers: evaluates configured header list in order

**Plugin Architecture:** Custom parser modules implement `RemoteIp.Parser` behavior, allowing non-standard header formats without library modifications.

**Important Requirement:** RemoteIp assumes your app sits behind **at least one proxy**. Do not use this plug in non-proxied environments (direct client connections).

## Configuration

All options support static values or runtime evaluation via MFA tuples `{module, function, arguments}`:

```elixir
plug RemoteIp, proxies: {System, :get_env, ["TRUSTED_PROXIES"]}
```

### Headers (`:headers`)

**Type:** List of strings  
**Default:** `["forwarded", "x-forwarded-for", "x-client-ip", "x-real-ip"]`

Specifies header names to examine for forwarding info. Production deployments should use a **singleton list** (one header) to avoid header-ordering ambiguities across infrastructure.

```elixir
plug RemoteIp, headers: ~w[x-forwarded-for]
```

### Parsers (`:parsers`)

**Type:** Map of header name → parser module  
**Default:** `%{"forwarded" => RemoteIp.Parsers.Forwarded}`

Maps custom headers to parser modules. Headers without explicit parsers use `RemoteIp.Parsers.Generic` (comma-separated). Map merges with defaults.

```elixir
plug RemoteIp, parsers: %{
  "x-custom" => MyApp.CustomIpParser
}
```

### Proxies (`:proxies`)

**Type:** List of strings (IPs or CIDR notation)  
**Default:** `[]` (but reserved ranges always skipped)

Known proxy server addresses to skip. Reserved ranges (loopback, private, IPv6 ULA) are automatically skipped regardless of config.

```elixir
plug RemoteIp, proxies: ~w[10.0.0.0/8 192.0.2.1]
```

### Clients (`:clients`)

**Type:** List of strings (IPs or CIDR notation)  
**Default:** `[]`

Known client addresses never treated as proxies. Overrides proxy designation, allowing normally-skipped reserved addresses if needed.

```elixir
plug RemoteIp, clients: ~w[10.0.0.100]
```

## Best Practices

**Security:**

- Always run RemoteIp with trusted proxies explicitly configured. An unconfigured plug trusting all headers is unsafe.
- Use singleton `:headers` lists in production to eliminate header-ordering attack surface.
- Validate proxy trust at your infrastructure boundary—RemoteIp only sanitizes IPs after verified proxy nodes.

**Infrastructure:**

- Verify your load balancer/reverse proxy emits consistent headers. Test with `RemoteIp.from/2` in isolation before deploying.
- For layered proxies (CDN → LB → app), trust only the outermost proxy address; intermediate proxies should not emit forwarding headers to the app.
- If your proxy uses `Forwarded` headers (RFC 7239), prefer it over generic headers for standards compliance.

**Debugging:**

- Use `RemoteIp.from(headers, options)` in iex/tests to validate header parsing before plugging into requests.
- Log both raw `Plug.Conn.remote_ip` and the computed value to detect misconfiguration.
- CIDR notation accepts both `/` formats: `10.0.0.0/8` and range notation via the `:ip` library.

---

**Version:** 1.2.0  
**Source:** [hexdocs.pm/remote_ip](https://hexdocs.pm/remote_ip/)  
**Generated:** 2026-04-25
