# hackney

HTTP client library for Erlang and Elixir with support for HTTP/1.1, HTTP/2, and HTTP/3, featuring connection pooling, streaming, and WebSocket support.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
{:hackney, "~> 1.25"}
```

Ensure the application is started:

```elixir
Application.ensure_all_started(:hackney)
```

### Basic Requests

**GET request:**

```elixir
{:ok, 200, headers, body} = :hackney.get("https://example.com")
```

**POST with JSON:**

```elixir
headers = [{"content-type", "application/json"}]
payload = "{\"key\": \"value\"}"
:hackney.post("https://example.com/api", headers, payload)
```

**Request with options:**

```elixir
:hackney.get(url, headers, "", [connect_timeout: 5000, recv_timeout: 30000])
```

## Core Concepts

### Connection Pooling

Hackney pools connections automatically. Create named pools for different services:

```elixir
:hackney_pool.start_pool(:api_pool, max_connections: 100)
:hackney.get(url, [], "", pool: :api_pool)
```

Disable pooling for one-off requests: `pool: false`

### Streaming

**Request streaming (uploads):**

```elixir
{:ok, ref} = :hackney.post(url, headers, :stream)
:hackney.send_body(ref, "chunk 1")
:hackney.send_body(ref, "chunk 2")
:hackney.finish_send_body(ref)
```

**Async response handling:**

```elixir
{:ok, ref} = :hackney.get(url, [], "", async: true)
receive do
  {:hackney_response, ^ref, {:status, status, _}} -> {:ok, status}
  {:hackney_response, ^ref, {:headers, headers}} -> {:ok, headers}
  {:hackney_response, ^ref, {:data, body}} -> {:ok, body}
end
```

### Protocol Support

- **HTTP/1.1**: Default, automatic fallback
- **HTTP/2**: Automatic negotiation; force with `protocols: [http2]`
- **HTTP/3**: Experimental; opt-in with `protocols: [http3, http2, http1]`
- **WebSocket**: Use `hackney.ws_connect/2` for WSS endpoints

## Configuration

### Common Options

| Option            | Default      | Purpose                          |
| ----------------- | ------------ | -------------------------------- |
| `connect_timeout` | 5000 ms      | Connection establishment timeout |
| `recv_timeout`    | 30000 ms     | Response wait timeout            |
| `follow_redirect` | false        | Auto-follow 3xx redirects        |
| `auto_decompress` | true         | Decompress gzip/deflate          |
| `ssl_verify`      | :verify_peer | SSL certificate validation       |
| `pool`            | :default     | Connection pool name or false    |

### Proxy Configuration

```elixir
:hackney.get(url, [], "", proxy: "http://proxy.example.com:8080")
```

### SSL/TLS

Hackney uses Mozilla's CA bundle by default. Override with:

```elixir
:hackney.get(url, [], "", cacertfile: "/path/to/certs.pem")
```

## Best Practices

### Pool Management

- Create separate pools for different services (API, payment gateway, etc.)
- Set `max_connections` based on expected concurrent load
- Use reasonable timeouts to avoid resource leaks
- Monitor connection state with `hackney_pool:get_stats/1`

### Timeout Strategy

- `connect_timeout`: 5-10 seconds for external APIs
- `recv_timeout`: 30-60 seconds for typical endpoints
- Shorter timeouts for internal services
- Always set both; never rely on defaults in production

### Error Handling

```elixir
case :hackney.get(url, [], "", recv_timeout: 30000) do
  {:ok, status, headers, body} when status in [200, 201] -> body
  {:ok, status, _headers, _body} -> {:error, "HTTP #{status}"}
  {:error, reason} -> {:error, reason}
end
```

### Resource Cleanup

For streaming requests, always close the connection:

```elixir
{:ok, ref} = :hackney.post(url, headers, :stream)
:hackney.send_body(ref, payload)
:hackney.finish_send_body(ref)
:hackney.close(ref)
```

### Multipart Uploads

Use `hackney_multipart` for form data:

```elixir
form = [{:file, "/path/to/file"}]
:hackney.post(url, [], {:multipart, form})
```

---

**Version:** 1.25.0
**Source:** [hexdocs.pm/hackney](https://hexdocs.pm/hackney/)
**Generated:** 2026-04-25
