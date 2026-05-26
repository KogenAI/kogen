# postgrex

PostgreSQL client and driver for Elixir with support for prepared statements, streaming, and multiple connection modes.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:postgrex, "~> 0.22.0"}
  ]
end
```

### Basic Connection

```elixir
{:ok, pid} = Postgrex.start_link(
  hostname: "localhost",
  username: "user",
  password: "password",
  database: "myapp_dev",
  port: 5432
)

Postgrex.query(pid, "SELECT * FROM posts WHERE id = $1", [42])
```

Connection accepts environment variables:

- `PGHOST` → `:hostname`
- `PGPORT` → `:port`
- `PGUSER` → `:username`
- `PGPASSWORD` → `:password`
- `PGDATABASE` → `:database`

## Core Concepts

### Connection Targets (priority order)

1. **UNIX Socket** (`:socket` or `:socket_dir`) — fastest, local connections only
2. **Endpoints** (`:endpoints`) — list of `{host, port}` tuples, tried in order
3. **Hostname + Port** (`:hostname`, `:port`) — standard TCP connection

### Query Execution

**Simple Query** — parse, plan, and execute in one round-trip:

```elixir
Postgrex.query!(conn, "SELECT * FROM posts", [])
```

**Prepared Statement** — reusable query plan:

```elixir
query = Postgrex.prepare!(conn, "get_post", "SELECT * FROM posts WHERE id = $1")
result = Postgrex.execute!(conn, query, [42])
Postgrex.close(conn, query)
```

**Prepared + Executed** — combine prepare and execute:

```elixir
Postgrex.prepare_execute!(conn, "", "SELECT * FROM posts WHERE id = $1", [42])
```

### Streaming

Process large result sets without buffering the entire response:

```elixir
stream = Postgrex.stream(conn, "SELECT * FROM large_table", [])
stream |> Stream.each(&IO.inspect/1) |> Stream.run()
```

### Transactions

```elixir
Postgrex.transaction(conn, fn conn ->
  Postgrex.query!(conn, "INSERT INTO posts (title) VALUES ($1)", ["New Post"])
  Postgrex.query!(conn, "UPDATE counters SET posts = posts + 1", [])
end)
```

Use `:savepoint` mode for nested transactions:

```elixir
Postgrex.transaction(conn, fn conn -> ... end, mode: :savepoint)
```

## Configuration

### Timeouts

| Option               | Purpose                       | Default             |
| -------------------- | ----------------------------- | ------------------- |
| `:timeout`           | Idle socket receive timeout   | 15000ms             |
| `:connect_timeout`   | TCP handshake                 | Inherits `:timeout` |
| `:handshake_timeout` | PostgreSQL protocol handshake | Inherits `:timeout` |
| `:ping_timeout`      | Keepalive interval            | Inherits `:timeout` |

### SSL/TLS

```elixir
Postgrex.start_link(
  hostname: "postgres.example.com",
  ssl: true  # Use system CA certs, auto-enable SNI
)
```

Custom SSL options:

```elixir
ssl: [
  verify: :verify_peer,
  cacertfile: "/etc/ssl/certs/ca-bundle.crt",
  server_name_indication: 'postgres.example.com'
]
```

### Failover & High Availability

```elixir
Postgrex.start_link(
  endpoints: [
    {"primary.rds.amazonaws.com", 5432},
    {"replica.rds.amazonaws.com", 5432}
  ],
  target_server_type: :primary  # Reconnect to primary if it fails
)
```

### Pool Configuration (with DBConnection)

```elixir
Postgrex.start_link(
  hostname: "localhost",
  database: "myapp_dev",
  pool_size: 10,
  max_overflow: 5,
  queue_target: 50,
  queue_interval: 1000
)
```

## Best Practices

### 1. Use Parameterized Queries

Always use parameter placeholders (`$1`, `$2`) to prevent SQL injection:

```elixir
# ✅ Safe
Postgrex.query(conn, "SELECT * FROM users WHERE email = $1", [email])

# ❌ Unsafe
Postgrex.query(conn, "SELECT * FROM users WHERE email = '#{email}'", [])
```

### 2. Prepared Statements for Repeated Queries

Reuse the same query multiple times:

```elixir
query = Postgrex.prepare!(conn, "upsert", """
  INSERT INTO posts (title, body) VALUES ($1, $2)
  ON CONFLICT (id) DO UPDATE SET body = EXCLUDED.body
""")

Postgrex.execute(conn, query, ["Title 1", "Body 1"])
Postgrex.execute(conn, query, ["Title 2", "Body 2"])
```

### 3. Stream Large Datasets

For queries returning thousands of rows, use streaming to avoid memory bloat:

```elixir
Postgrex.stream(conn, "SELECT * FROM audit_logs", [])
|> Stream.chunk_every(1000)
|> Stream.each(&process_batch/1)
|> Stream.run()
```

### 4. Connection Pooling

In production, always use a connection pool (via DBConnection):

```elixir
# config/runtime.exs
config :myapp, MyApp.Repo,
  pool_size: System.get_env("DB_POOL_SIZE", "10") |> String.to_integer(),
  ssl: System.get_env("DATABASE_SSL") == "true"
```

### 5. Error Handling

```elixir
case Postgrex.query(conn, sql, params) do
  {:ok, result} -> result.rows
  {:error, %Postgrex.Error{message: msg}} -> {:error, msg}
  {:error, reason} -> {:error, reason}
end
```

### 6. Transaction Rollback

Use `Postgrex.transaction/3` for automatic rollback on error:

```elixir
Postgrex.transaction(conn, fn conn ->
  Postgrex.query!(conn, "INSERT INTO posts (title) VALUES ($1)", ["New Post"])
  # Any exception or explicit :error return triggers rollback
end)
```

### 7. Connection Lifecycle

Always clean up connections:

```elixir
{:ok, pid} = Postgrex.start_link(...)
try do
  result = Postgrex.query!(pid, ...)
  result
finally
  GenServer.stop(pid)
end
```

### 8. Monitoring & Health Checks

Use `:ping_timeout` to detect stale connections:

```elixir
Postgrex.start_link(
  hostname: "localhost",
  ping_timeout: 30000,  # Ping every 30s
  idle_interval: 5000   # Check idle connection
)
```

---

**Version:** 0.22.0
**Source:** [hexdocs.pm/postgrex](https://hexdocs.pm/postgrex/)
**Generated:** 2026-04-25
