# db_connection

An Elixir library providing efficient database connection pooling and transaction management through a behavior-based architecture. DBConnection handles socket state directly through callers rather than traditional message passing, reducing overhead and enabling responsive connection processes.

## Quick Start

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:db_connection, "~> 2.10"}
  ]
end
```

Basic pool startup:

```elixir
{:ok, pid} = DBConnection.start_link(MyDatabase, [hostname: "localhost"])
DBConnection.execute(pid, "SELECT * FROM users", [])
```

## Core Concepts

### Connection Behavior

Implement the `DBConnection` behavior in your adapter module:

```elixir
defmodule MyDatabase do
  @behaviour DBConnection

  def connect(opts) do
    # Establish socket connection to database
    {:ok, socket}
  end

  def handle_execute(query, params, _opts, state) do
    # Execute query and return results
    {:ok, result, state}
  end

  def handle_begin(_opts, state) do
    {:ok, state}
  end

  def handle_commit(_opts, state) do
    {:ok, state}
  end

  def handle_rollback(_opts, state) do
    {:ok, state}
  end

  def ping(state) do
    # Check connection health
    {:ok, state}
  end
end
```

### State Management

DBConnection copies connection state to calling processes via ETS, allowing direct socket interaction while keeping the connection process responsive to OTP messages. The holder (ETS table) tracks connection and checkout states.

### Pool Queue Algorithm

The connection pool uses CoDel (Controlled Delay) queuing to gracefully handle overloads by rejecting requests when the pool is congested, rather than indefinitely queuing them.

## Configuration

### Pool Options

- `:pool` - Connection pool implementation (default: `DBConnection.ConnectionPool`)
- `:pool_size` - Number of connections to maintain (default: 10)
- `:max_overflow` - Extra connections allowed when pool is exhausted (default: 0)
- `:queue_target` - Milliseconds to aim for queue wait time (CoDel tuning)
- `:queue_interval` - Milliseconds between queue inspections (CoDel tuning)

### Reconnection Strategy

DBConnection implements configurable exponential random backoff for reconnection attempts:

```elixir
{:ok, pid} = DBConnection.start_link(MyDatabase, [
  hostname: "localhost",
  backoff_min: 1_000,
  backoff_max: 30_000
])
```

### Dynamic Configuration

Use the `:configure` callback to modify options before each connection attempt:

```elixir
def configure(opts) do
  # Useful for per-connection database assignment during testing
  {:ok, Keyword.put(opts, :database, test_db_name())}
end
```

### Idle Connection Management

DBConnection periodically pings idle connections to maintain database connectivity and prevent connection staleness. Configure ping intervals with the `:idle_interval` option.

## Primary Functions

**`start_link(module, opts)`** - Initialize a connection pool with the specified behavior module and configuration options.

**`execute(conn, query, params, opts \\ [])`** - Run queries with parameters, returning results or errors.

**`transaction(conn, fun, opts \\ [])`** - Execute a function within a database transaction, with automatic rollback on error.

**`prepare(conn, query, opts \\ [])`** - Pre-compile queries for repeated execution, returning a prepared statement handle.

**`stream(conn, query, params, opts \\ [])`** - Stream query results using database cursors for memory-efficient large result processing.

**`run(conn, fun, opts \\ [])`** - Execute a series of requests on a locked connection, useful for multi-step operations.

## Best Practices

### Connection Lifecycle

Always use `start_link` to integrate with supervisor trees. Let the pool manage connection creation and destruction:

```elixir
defmodule MyApp.Repo do
  def start_link(opts) do
    DBConnection.start_link(MyDatabase, opts)
  end
end
```

### Error Handling

Handle connection failures gracefully:

- Use timeout options to prevent indefinite waits
- Implement proper `:on_connect` hooks for initialization
- Configure backoff parameters for production workloads

### Transaction Safety

Transactions automatically rollback on errors. Use them for atomic operations:

```elixir
DBConnection.transaction(pid, fn conn ->
  {:ok, _} = DBConnection.execute(conn, "INSERT INTO users ...", [])
  {:ok, result} = DBConnection.execute(conn, "SELECT * FROM users", [])
  {:ok, result}
end)
```

### Query Preparation

Prepare frequently-used queries to reduce parsing overhead:

```elixir
{:ok, prepared} = DBConnection.prepare(conn, "SELECT * FROM users WHERE id = ?")
DBConnection.execute(conn, prepared, [user_id])
```

### Monitoring Connections

The holder uses deadline management: clients must return checked-out connections within the timeout window, or the connection is automatically terminated and removed from the pool. This prevents socket reuse in corrupted states.

### Adapter Development

Refer to `./examples/` in the repository for reference implementations. The library is specifically designed to support database adapter libraries by handling pooling and transactions transparently.

---

**Version:** 2.10.2
**Source:** [hexdocs.pm/db_connection](https://hexdocs.pm/db_connection/2.10.2)
**Generated:** 2026-08-07
