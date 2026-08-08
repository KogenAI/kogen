# postgrex

Postgrex is a PostgreSQL driver for Elixir that provides type-safe connections to PostgreSQL databases with automatic type conversion between Elixir and PostgreSQL binary formats.

## Quick Start

**Installation:**

Add to `mix.exs`:

```elixir
{:postgrex, "~> 0.22.4"}
```

**Basic Connection:**

```elixir
{:ok, pid} = Postgrex.start_link(
  hostname: "localhost",
  username: "postgres",
  password: "postgres",
  database: "postgres"
)
```

**Basic Query:**

```elixir
# Select query
Postgrex.query!(pid, "SELECT user_id, text FROM comments", [])

# Insert query
Postgrex.query!(pid, "INSERT INTO comments (user_id, text) VALUES (10, 'heya')", [])
```

## Core Concepts

**Automatic Type Conversion:**
Postgrex automatically converts between Elixir values and PostgreSQL binary format:

- `NULL` ↔ `nil`
- `bool` ↔ `true`/`false`
- `int` ↔ integer values
- `text` ↔ strings
- `date` ↔ `Date` struct
- `timestamp` ↔ `NaiveDateTime`
- `timestamptz` ↔ `DateTime`
- Arrays, UUIDs, and composite types supported

**DBConnection Integration:**
Postgrex uses DBConnection protocol for:

- Connection pooling
- Transaction support
- Prepared queries
- Connection lifecycle management

**Type Safety:**
Postgrex enforces proper type matching. Parameter types must match PostgreSQL expectations—automatic casting is not performed.

## Configuration

**Connection Options:**

- `hostname`: PostgreSQL server hostname (default: "localhost")
- `username`: Database user
- `password`: User password
- `database`: Database name
- `port`: Port number (default: 5432)
- `socket_dir`: Unix socket directory
- `ssl`: Enable SSL/TLS (true/false or `:verify_peer`)
- `timeout`: Connection timeout in milliseconds
- `prepare`: `:named` (default) or `:unnamed` for PgBouncer compatibility

**JSON Support:**

Add `:jason` dependency to `mix.exs`:

```elixir
{:jason, "~> 1.0"}
```

Configure in `start_link`:

```elixir
Postgrex.start_link(
  hostname: "localhost",
  username: "postgres",
  password: "postgres",
  database: "postgres",
  json_library: Jason  # Optional, Jason is default
)
```

**Custom Type Extensions:**

Define custom type encoders/decoders:

```elixir
defmodule MyApp.Types do
  def define(extensions) do
    Postgrex.Types.define(__MODULE__, extensions, json: Jason)
  end
end
```

Then pass to `start_link`:

```elixir
Postgrex.start_link(
  hostname: "localhost",
  username: "postgres",
  password: "postgres",
  database: "postgres",
  types: MyApp.Types
)
```

**PgBouncer Compatibility:**

For PgBouncer versions below 1.21.0 with transaction or statement pooling, use unnamed prepared statements:

```elixir
Postgrex.start_link(
  hostname: "localhost",
  username: "postgres",
  password: "postgres",
  database: "postgres",
  prepare: :unnamed
)
```

## Best Practices

**Type Casting:**
Postgrex does not automatically cast between types. Provide correctly-typed parameters or use explicit SQL casts:

```elixir
# Correct - parameter type matches PostgreSQL expectation
Postgrex.query!(pid, "SELECT * FROM users WHERE id = $1", [123])

# With explicit cast if needed
Postgrex.query!(pid, "SELECT * FROM users WHERE id = $1::integer", ["123"])
```

**Connection Pooling:**
Use DBConnection-compatible pooling libraries (like Poolboy or built-in connection management) in production to handle multiple concurrent queries efficiently.

**Error Handling:**
Use `Postgrex.query/3` for error tuples or `Postgrex.query!/3` for exceptions:

```elixir
case Postgrex.query(pid, "SELECT ...", []) do
  {:ok, result} -> handle_result(result)
  {:error, error} -> handle_error(error)
end
```

**PostgreSQL Compatibility:**
Supports PostgreSQL 8.4, 9.0-9.6, and later versions.

---

**Version:** 0.22.4
**Source:** [hexdocs.pm/postgrex](https://hexdocs.pm/postgrex)
**Generated:** 2026-08-08
