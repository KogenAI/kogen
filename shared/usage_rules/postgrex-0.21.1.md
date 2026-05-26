# postgrex

Postgrex is a pure Elixir PostgreSQL driver implementing the Postgres frontend/backend message protocol. It performs wire messaging directly in Elixir without binding to C libraries like libpq.

## Quick Start

### Installation

Add to `mix.exs` dependencies:

```elixir
def deps do
  [
    {:postgrex, "~> 0.21.1"}
  ]
end
```

### Basic Connection

```elixir
# Start a connection
{:ok, pid} = Postgrex.start_link(
  hostname: "localhost",
  username: "user",
  password: "pass",
  database: "mydb"
)

# Execute a query
{:ok, result} = Postgrex.query(pid, "SELECT * FROM users WHERE id = $1", [1])

# Get rows as maps
Enum.map(result.rows, &Enum.zip(result.columns, &1) |> Map.new)
```

## Core Concepts

### Connection Management

Postgrex provides pure Elixir wire protocol implementation without relying on external C libraries. Connection initialization uses `start_link/1` with various configuration options for TCP sockets, Unix sockets, or multiple endpoint lists for connection pooling.

**Key Functions:**

- `start_link/1` - Establish PostgreSQL connection
- `transaction/3` - Execute operations within a transaction context
- `rollback/2` - Abort current transaction
- `close/3` - Release prepared statement resources

### Query Execution

Postgrex implements extended queries with separate parse, bind, and execute stages for efficient query caching without relying on SQL `PREPARE` and `EXECUTE` statements.

**Query Functions:**

- `query/4` and `query!/4` - Execute queries directly (returns `{:ok, result}` or raises)
- `prepare/4` and `prepare!/4` - Prepare statements for reuse
- `execute/4` and `execute!/4` - Run prepared queries
- `prepare_execute/5` - Combine preparation and execution in one call

### Streaming Large Results

```elixir
# Stream large result sets for memory efficiency
Postgrex.stream(pid, "SELECT * FROM large_table", [])
|> Stream.map(fn %{rows: rows} -> rows end)
|> Stream.each(&process_batch/1)
|> Stream.run
```

The `stream/4` function processes large datasets in memory-efficient chunks without loading entire result sets.

## Configuration

### Connection Options

**Basic Settings:**

- `:hostname` - PostgreSQL server host (TCP) or socket directory (Unix)
- `:port` - Server port (default: 5432 for TCP)
- `:username` - Database user
- `:password` - User password
- `:database` - Database name to connect to
- `:socket` - Alternative to `:hostname`/`:port` for Unix socket connections
- `:sockets` - List of sockets for multiple endpoint connections

**Query Preparation:**

- `:prepare` - Strategy for prepared statements
  - `:named` (default) - Uses server-side statement caching via `PREPARE`
  - `:unnamed` - Uses unnamed statements (required for PgBouncer compatibility)

**SSL/TLS:**

- `:ssl` - Enable SSL (boolean or `:required`)
- `:cacertfile` - Path to CA certificate for verification
- `:keyfile` - Client private key path
- `:certfile` - Client certificate path

**Other Options:**

- `:pool_size` - Connection pool size (when used with pooling library)
- `:parameters` - Map of custom PostgreSQL parameters
- `:connect_timeout` - Connection timeout in milliseconds

### Socket Name Derivation

When using Unix sockets, the socket name is automatically derived based on the port number when not explicitly provided. This enables automatic discovery of socket files.

## Best Practices

### Use Transactions for Related Operations

```elixir
{:ok, result} = Postgrex.transaction(pid, fn conn ->
  Postgrex.query!(conn, "UPDATE accounts SET balance = balance - $1 WHERE id = $2", [100, 1])
  Postgrex.query!(conn, "UPDATE accounts SET balance = balance + $1 WHERE id = $2", [100, 2])
end)
```

Transactions ensure atomic operations and data consistency across multiple queries.

### Leverage Query Caching with Named Statements

Named prepared statements cache on the server, improving performance for repeated queries:

```elixir
{:ok, _} = Postgrex.prepare(pid, "get_user", "SELECT * FROM users WHERE id = $1")
{:ok, result} = Postgrex.execute(pid, "get_user", [1])
```

### PgBouncer Compatibility

When using PgBouncer connection pooling, set `:prepare` to `:unnamed` to disable server-side statement caching:

```elixir
{:ok, pid} = Postgrex.start_link(
  hostname: "localhost",
  prepare: :unnamed,
  # other config...
)
```

Named prepared statements conflict with PgBouncer's transaction pooling.

### SSL Certificate Verification

Always verify SSL certificates in production:

```elixir
{:ok, pid} = Postgrex.start_link(
  hostname: "production.db.example.com",
  ssl: true,
  cacertfile: "/path/to/ca-cert.pem",
  # other config...
)
```

### Stream Large Result Sets

Use `stream/4` for memory-efficient processing of large datasets instead of loading entire result sets:

```elixir
Postgrex.stream(pid, "SELECT * FROM large_table", [])
|> Stream.chunk_every(1000)
|> Stream.each(&Repo.insert_all(MyModule, &1))
|> Stream.run
```

### Error Handling

```elixir
case Postgrex.query(pid, sql, params) do
  {:ok, result} -> handle_success(result)
  {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} -> handle_duplicate()
  {:error, reason} -> handle_error(reason)
end
```

Postgrex.Error contains PostgreSQL-specific error information via the `:postgres` field.

### Parameters Access

Access connection parameters for debugging and configuration validation:

```elixir
params = Postgrex.parameters(pid)
# Returns map like: %{"server_version" => "120000", "client_encoding" => "UTF8"}
```

---

**Version:** 0.21.1
**Source:** [hexdocs.pm/postgrex](https://hexdocs.pm/postgrex/)
**Generated:** 2025-10-28
