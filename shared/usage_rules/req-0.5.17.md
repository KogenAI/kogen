# req

Req is a batteries-included HTTP client for Elixir that combines a high-level API (`Req`), structured request/response objects (`Req.Request`), built-in middleware steps (`Req.Steps`), and testing utilities (`Req.Test`). It handles common HTTP patterns—authentication, retries, redirects, compression, streaming—with sensible defaults while remaining customizable.

## Quick Start

**Installation:**
Add to `mix.exs`:

```elixir
{:req, "~> 0.5"}
```

**Basic GET:**

```elixir
Req.get!("https://api.github.com/repos/wojtekmach/req").body["description"]
```

**Using bang functions** (`Req.get!`, `Req.post!`) raises on error. Non-bang versions return `{:ok, response}` or `{:error, exception}` tuples.

**Create a reusable request:**

```elixir
req = Req.new(base_url: "https://api.github.com")
Req.get!(req, url: "/repos/wojtekmach/req")
```

## Core Concepts

**Four-module architecture:**

- `Req` — high-level API (get, post, request, new, etc.)
- `Req.Request` — request struct with configuration
- `Req.Steps` — built-in middleware for encoding, auth, retry, redirect
- `Req.Test` — mock/testing utilities

**Header handling:**
Headers are stored downcased and automatically case-normalized on access, following the "list of tuples" convention for Erlang/Elixir HTTP interoperability.

**Request-response flow:**
`Req.request/2` applies a series of steps: encode body, add auth, follow redirects, retry on transient errors. Returns a `Req.Response` struct containing `:status`, `:headers`, `:body`.

**Base URL pattern:**
Set `:base_url` once; relative URLs are automatically prepended, reducing repetition across multiple API calls.

## Configuration

**Request anatomy:**

```elixir
Req.new(
  base_url: "https://api.example.com",
  auth: {:bearer, token},
  params: [page: 1],
  headers: [custom_header: "value"],
  retry: :transient,
  redirect: true,
  max_redirects: 10
)
```

**Encoding:**

- `:form` — URL-encoded form data (POST/PUT)
- `:form_multipart` — multipart form (file uploads)
- `:json` — JSON encoding (auto-detected on `:body` maps/lists)
- `:compress_body` — gzip compression (optional)

**Authentication:**

- `{:basic, "user:password"}` — HTTP Basic Auth
- `{:bearer, token}` — Bearer token
- Custom function `(req -> req)` — dynamic auth headers

**Streaming responses:**

- `:into` callback — process chunks as they arrive
- `:into => :self` — receive chunks in current process mailbox
- `:into => File` — stream to a file

**Timeout & retry:**

- `:connect_options => [timeout: ms]` — connection timeout
- `:receive_timeout => ms` — read timeout (default: 15,000)
- `:pool_timeout => ms` — connection pool wait (default: 5,000)
- `:retry` — `:transient` (default, retries 4xx/5xx/connection errors), `:safe` (idempotent only), or custom logic

**Redirect control:**

- `:redirect => true` — follow redirects (default)
- `:max_redirects => 10` — limit hops (default: 10)

**Error handling:**

- `:http_errors => :raise` — raise on 4xx/5xx (default for bang functions)
- `:http_errors => :return` — return response even on error

## Best Practices

**Reuse request objects:**
Create a `Req.new` once with shared config (base_url, auth, timeouts) and pass it to multiple calls. Use `Req.merge/2` to update for specific requests.

**Example:**

```elixir
req = Req.new(
  base_url: "https://api.example.com",
  auth: {:bearer, System.get_env!("API_TOKEN")}
)

Req.get!(req, url: "/users")
Req.post!(req, url: "/events", json: %{action: "click"})
```

**Handle errors gracefully:**
Prefer non-bang functions (`Req.get`) in library code; use bang functions (`Req.get!`) in scripts and tests where you want immediate failure feedback.

```elixir
case Req.get(req, url: "/resource") do
  {:ok, resp} -> process(resp.body)
  {:error, reason} -> Logger.error("Request failed: #{inspect(reason)}")
end
```

**Stream large responses:**
Use `:into` for files, streaming APIs, or backpressure control:

```elixir
Req.get!(req, url: "/download", into: File.stream!("output.bin"))
```

**Configure retry sensibly:**

- `:retry => :transient` (default) — safe for all methods, retries connection errors and 5xx
- `:retry => :safe` — only idempotent methods (GET, HEAD, DELETE)
- Disable with `:retry => false` if endpoint is not idempotent

**Compress request bodies:**
Set `:compress_body` for large POST/PUT payloads; server must support gzip.

**Global defaults (discouraged for libraries):**
`Req.default_options(base_url: "...")` sets library-wide defaults. Avoid in shared code; pass config explicitly instead.

---

**Version:** 0.5.17
**Source:** [hexdocs.pm/req](https://hexdocs.pm/req/)
**Generated:** 2026-04-25
