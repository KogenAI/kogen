# hpax

A lightweight Elixir library for secure HTTP basic authentication. HPAX provides utilities for encoding and decoding HTTP Authorization headers using the Basic authentication scheme, with built-in support for credential validation and secure header manipulation.

## Quick Start

### Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:hpax, "~> 1.0.3"}
  ]
end
```

Run `mix deps.get`.

### Basic Usage

```elixir
# Encode credentials to Authorization header
{:ok, header} = HPAX.encode("username", "password")
# Returns: {"Authorization", "Basic dXNlcm5hbWU6cGFzc3dvcmQ="}

# Decode Authorization header
{:ok, username, password} = HPAX.decode("Basic dXNlcm5hbWU6cGFzc3dvcmQ=")
# Returns: {:ok, "username", "password"}

# Get basic auth from connection (Phoenix)
case HPAX.decode_pair(conn) do
  {:ok, username, password} -> authenticate(username, password)
  :error -> send_resp(conn, 401, "Unauthorized")
end
```

## Core Concepts

### Encoding Credentials

The `HPAX.encode/2` function combines username and password using the format `username:password`, then Base64-encodes the result and prepends "Basic ".

```elixir
# Simple credentials
HPAX.encode("admin", "secret123")
# {:ok, {"Authorization", "Basic YWRtaW46c2VjcmV0MTIz"}}

# Credentials with special characters
HPAX.encode("user@domain.com", "p@ss:word")
# {:ok, {"Authorization", "Basic dXNlckBkb21haW4uY29tOnBAc3M6d29yZA=="}}
```

### Decoding Authorization Headers

The `HPAX.decode/1` function reverses the encoding process. It expects the full header value including the "Basic " prefix.

```elixir
# Full header value
HPAX.decode("Basic dXNlcm5hbWU6cGFzc3dvcmQ=")
# {:ok, "username", "password"}

# Invalid format returns error
HPAX.decode("Bearer token123")
# :error

HPAX.decode("malformed_base64")
# :error
```

### Connection Integration

For Phoenix applications, use `HPAX.decode_pair/1` to extract credentials directly from the connection's Authorization header:

```elixir
defmodule MyApp.AuthPlug do
  def call(conn, _opts) do
    case HPAX.decode_pair(conn) do
      {:ok, username, password} ->
        assign(conn, :current_user, authenticate(username, password))

      :error ->
        conn
        |> send_resp(401, "")
        |> halt()
    end
  end
end
```

## Configuration

HPAX requires no application configuration. It operates as a pure encoding/decoding library.

For Phoenix routes, add authentication middleware:

```elixir
# In your router
pipeline :api do
  plug MyApp.AuthPlug
end

scope "/api", MyApp do
  pipe_through :api
  # Protected routes
end
```

## Best Practices

### 1. Always Use HTTPS

Basic authentication transmits credentials in Base64 (easily reversible). Always use HTTPS in production:

```elixir
# In config/prod.exs
config :my_app, MyApp.Endpoint,
  url: [scheme: "https", host: "example.com"]
```

### 2. Validate Credentials Securely

Never trust Base64-decoded values directly. Always validate against a secure credential store:

```elixir
case HPAX.decode(auth_header) do
  {:ok, username, password} ->
    case User.authenticate(username, password) do
      {:ok, user} -> assign(conn, :user, user)
      :error -> unauthorized(conn)
    end

  :error -> unauthorized(conn)
end
```

### 3. Handle Edge Cases

Be defensive when parsing Authorization headers:

```elixir
defmodule AuthHandler do
  def authenticate(conn) do
    case get_req_header(conn, "authorization") do
      [header | _] -> HPAX.decode(header)
      [] -> :error
    end
  end
end
```

### 4. Cache Authentication Results

Use session tokens instead of re-validating credentials on every request:

```elixir
# After successful authentication
conn
|> put_session(:user_id, user.id)
|> put_session(:token, generate_token())
|> configure_session(renew: true)
```

### 5. Rate Limiting

Implement rate limiting on authentication endpoints to prevent brute force:

```elixir
# Use a library like ExRated or implement custom rate limiting
plug :rate_limit, [limit: 5, window: 60]  # 5 attempts per minute
```

### 6. Log Authentication Attempts

Log successful and failed attempts for security auditing:

```elixir
case HPAX.decode(auth_header) do
  {:ok, username, _password} ->
    Logger.info("Authentication attempt for user: #{username}")
    # Continue...

  :error ->
    Logger.warn("Failed authentication attempt")
    unauthorized(conn)
end
```

## Error Handling

HPAX functions return standard Elixir result tuples:

```elixir
# Successful decode
{:ok, username, password} = HPAX.decode("Basic dXNlcjpwYXNz")

# Failed decode (invalid format, malformed Base64, etc.)
:error = HPAX.decode("Invalid header")
```

Always pattern match on results and handle `:error` cases explicitly.

## Version Notes

**v1.0.3** is stable and feature-complete for basic HTTP authentication. The library follows the HTTP RFC 7617 Basic Authentication specification.

---

**Version:** 1.0.3  
**Source:** https://hexdocs.pm/hpax  
**Generated:** 2026-06-17
