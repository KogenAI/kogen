# req

Req is a batteries-included HTTP client for Elixir featuring a high-level API, built-in processing steps for request/response handling, automatic retries, caching, authentication, and integrated testing utilities. Four main modules compose the library: `Req` (high-level API), `Req.Request` (low-level API), `Req.Steps` (middleware), and `Req.Test` (testing utilities).

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:req, "~> 0.5"}
  ]
end
```

### Basic HTTP Methods

Req provides paired functions for each HTTP verb—one returning result tuples, another raising on errors:

```elixir
# GET request
Req.get!("https://api.github.com/repos/wojtekmach/req")
Req.get("https://api.github.com/repos/wojtekmach/req")

# POST with form data
Req.post!("https://httpbin.org/post", form: [comments: "hello!"])

# Other verbs: Req.put!, Req.patch!, Req.delete!, Req.head!
```

### Creating Persistent Clients

Use `Req.new()` to create a reusable request client with shared configuration:

```elixir
# Base URL configuration
req = Req.new(base_url: "https://api.github.com")
Req.get!(req, url: "/repos/wojtekmach/req")

# With default headers and auth
req = Req.new(
  base_url: "https://api.example.com",
  headers: [authorization: "Bearer token"],
  auth: {:bearer, "token"}
)
```

## Core Concepts

### Request Options

Create requests with options to `Req.new()`, `Req.request()`, or HTTP verb functions:

**Basic options:**

- `:method` - HTTP method (`:get`, `:post`, etc.)
- `:url` - Request URL
- `:headers` - Request headers as enumerable
- `:body` - Request body (iodata or enumerable)

**Body encoding:**

- `:form` - Encode as `application/x-www-form-urlencoded`
- `:form_multipart` - Encode as `multipart/form-data` (file uploads)
- `:json` - Encode as JSON

**Response handling:**

- `:into` - Control response destination (nil, callback, collectable, or `:self` for streaming)
- `:raw` - Disable automatic decompression/decoding
- `:decode_body` - Enable/disable response body decoding (default: true)

**Authentication:**

- `:auth` - Support `:basic`, `:bearer`, or `:netrc` authentication

**Advanced:**

- `:redirect` - Follow redirects (default: true)
- `:retry` - Automatic retry with exponential backoff
- `:cache` - Enable HTTP caching via `if-modified-since` headers
- `:aws_sigv4` - AWS Signature Version 4 signing

### Built-in Processing Steps

Req uses middleware steps for request/response processing. Key steps:

**Request Steps:**

- `auth()` - Apply authentication credentials
- `put_base_url()` - Set base URL for relative paths
- `put_params()` - Add query parameters
- `put_path_params()` - Template path parameters
- `encode_body()` - Encode form/JSON bodies
- `compress_body()` - Apply gzip compression
- `put_user_agent()` - Set user agent header

**Response Steps:**

- `decompress_body()` - Decompress gzip, Brotli, Zstandard
- `decode_body()` - Parse JSON, archives, CSV automatically
- `redirect()` - Follow location headers (configurable limits)
- `handle_http_errors()` - Raise on 4xx/5xx or handle gracefully

**Adapters:**

- `run_finch()` - Default HTTP client (Finch-based)
- `run_plug()` - Test against local Plug without network

### Streaming Responses

Stream large responses to avoid memory issues:

```elixir
# Stream with callback
Req.get!("http://httpbin.org/stream/2",
  into: fn {:data, data}, {req, resp} ->
    IO.puts(data)
    {:cont, {req, resp}}
  end)

# Stream with :self (receive messages)
resp = Req.get!("http://httpbin.org/stream/2", into: :self)
receive do
  message -> Req.parse_message(resp, message)
end
```

## Configuration

### Default Options

Set global defaults for all new requests:

```elixir
Req.default_options(
  base_url: "https://httpbin.org",
  headers: [user_agent: "MyApp/1.0"]
)
```

### Merging Options

Update existing request configuration:

```elixir
# Merges intelligently (headers, params combined not replaced)
req = Req.new(base_url: "https://api.example.com")
req = Req.merge(req, headers: [authorization: "Bearer token"])
```

### Retry Configuration

Control automatic retry behavior:

```elixir
Req.new(
  retry: :safe_transient  # Retries GET/HEAD on timeouts, connection errors
)

# Custom retry with delay function
Req.new(
  retry: fn attempt ->
    # exponential backoff: 100ms, 200ms, 400ms, etc.
    Integer.pow(2, attempt) * 100
  end
)
```

Default retry attempts: 3 (total 4 requests including original).

## Best Practices

### Use Persistent Clients

Create a module with shared HTTP client configuration instead of creating new requests repeatedly:

```elixir
defmodule MyApp.HTTPClient do
  def client do
    Req.new(
      base_url: "https://api.example.com",
      auth: {:bearer, System.get_env("API_TOKEN")},
      retry: :safe_transient
    )
  end
end
```

### Handle Errors Gracefully

Use `{:ok, response} | {:error, exception}` pattern for production code:

```elixir
case Req.get(client, url: "/endpoint") do
  {:ok, response} -> handle_success(response)
  {:error, exception} -> handle_error(exception)
end
```

Use `!` variants only in tests or controlled environments.

### Test with Req.Test

Mock HTTP requests without network calls:

```elixir
Req.Test.stub(:my_api, fn conn ->
  Req.Test.json(conn, %{"status" => "ok"})
end)

req = Req.new(plug: {Req.Test, :my_api})
Req.get!(req, url: "/status")
```

Use `expect()` for ordered request verification:

```elixir
Req.Test.expect(:my_api, 1, fn conn ->
  Req.Test.json(conn, %{"status" => "ok"})
end)

# Verify all expectations fulfilled
Req.Test.verify!(:my_api)
```

### Enable Caching for Repeated Requests

Use HTTP caching to reduce redundant requests:

```elixir
Req.new(
  base_url: "https://api.example.com",
  cache: true  # Honors if-modified-since headers
)
```

### Manage Header Case-Insensitivity

Headers are stored lowercase. Access headers safely:

```elixir
Req.Response.get_header(response, "content-type")
```

Don't assume exact header casing in responses.

---

**Version:** 0.5.15
**Source:** [hexdocs.pm/req](https://hexdocs.pm/req/)
**Generated:** 2025-10-28
