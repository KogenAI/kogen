# ecto_sql

SQL adapter for the Elixir Ecto library, providing standardized database access through built-in adapters for PostgreSQL, MySQL, and SQL Server. Handles connection pooling, migrations, query execution, and test isolation.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
defp deps do
  [
    {:ecto_sql, "~> 3.13"},
    {:postgrex, ">= 0.0.0"},  # or {:myxql, ">= 0.0.0"} for MySQL
  ]
end
```

### Repository Setup

Create your repo module:

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.Postgres
end
```

Configure in `config/config.exs`:

```elixir
config :my_app, MyApp.Repo,
  database: "my_app_db",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5432
```

### Basic Operations

```elixir
# Query operations
MyRepo.all(Post)                        # Fetch all posts
MyRepo.get(Post, id)                    # Get by primary key
MyRepo.get_by(Post, title: "My post")   # Fetch by conditions
MyRepo.one(query)                       # Fetch single result
MyRepo.exists?(Post)                    # Check existence

# Mutations
MyRepo.insert(changeset)                # Insert new record
MyRepo.update(changeset)                # Update existing record
MyRepo.delete(struct)                   # Delete record
MyRepo.insert_all(Post, entries)        # Batch insert
```

## Core Concepts

### Database Adapters

Three built-in adapters available:

- **Postgres** (`Ecto.Adapters.Postgres`) — Full-featured, recommended
- **MySQL** (via `:myxql`) — Via `Ecto.Adapters.MySQL`
- **SQL Server** (via `:tds`) — Via `Ecto.Adapters.SQLServer`

### Query Execution

Raw SQL queries with parameter binding:

```elixir
MyRepo.query("SELECT * FROM users WHERE id = $1", [user_id])
# Returns: %Postgrex.Result{num_rows: 1, rows: [row_data]}

MyRepo.query!("INSERT INTO logs (msg) VALUES ($1)", ["test message"])
```

### Migrations

Directory: `priv/repo/migrations/` (configurable via `:priv`)

Generate migration:

```
$ mix ecto.gen.migration create_users
```

Run migrations:

```
$ mix ecto.migrate              # Run all pending
$ mix ecto.migrate --step 3     # Run 3 migrations
$ mix ecto.migrate --to 20240101000000  # Run up to version
$ mix ecto.rollback             # Undo last
```

Custom migration directory:

```elixir
config :my_app, MyApp.Repo, priv: "priv/custom_repo"
```

### Transactions

```elixir
MyRepo.transaction(fn ->
  {:ok, alice} = MyRepo.insert(alice_changeset)
  {:ok, bob} = MyRepo.insert(bob_changeset)
  {:ok, [alice, bob]}
end)

# With options
MyRepo.transaction(fn ->
  # ...
end, timeout: 30000, isolation: :serializable)
```

### Query Analysis

Inspect execution plans without modifying data:

```elixir
MyRepo.explain(:all, Post)              # PostgreSQL EXPLAIN
MyRepo.explain(:delete_all, Post)       # Works with any command

# With options (adapter-specific)
MyRepo.explain(:all, Post, analyze: true, verbose: true)
```

PostgreSQL options: `analyze`, `verbose`, `costs`, `buffers`, `timing`
MySQL options: `format`, `wrap_in_transaction`

## Configuration

### Connection Options

| Option        | Default     | Description                                           |
| ------------- | ----------- | ----------------------------------------------------- |
| `:name`       | Derived     | Supervisor process identifier                         |
| `:hostname`   | Required    | Database host                                         |
| `:port`       | 5432 (PG)   | Database port                                         |
| `:username`   | Required    | Login user                                            |
| `:password`   | Required    | Login password                                        |
| `:database`   | Required    | Database name                                         |
| `:pool_size`  | 10          | Connection pool size                                  |
| `:pool_count` | 1           | Number of concurrent pools                            |
| `:log`        | :debug      | Logging level (`:debug` or `false`)                   |
| `:url`        | —           | Connection string: `"ecto://user:pass@host/database"` |
| `:priv`       | "priv/repo" | Migration directory base                              |

### Advanced Options

```elixir
config :my_app, MyApp.Repo,
  # Connection pooling
  pool_size: 20,
  pool_count: 2,

  # Telemetry
  telemetry_prefix: [:my_app, :repo],

  # Testing
  pool: Ecto.Adapters.SQL.Sandbox,  # In config/test.exs

  # Performance
  queue_target: 50,  # Milliseconds
  queue_interval: 1000,

  # Timeouts
  ownership_timeout: 60000,  # Milliseconds

  # Dynamic repos
  name: :my_dynamic_repo
```

### Multiple Databases

```elixir
# Use different repos
config :my_app, MyApp.Repo, database: "my_app_prod"
config :my_app, MyApp.AnalyticsRepo, database: "analytics"

# Or dynamically switch
MyApp.Repo.put_dynamic_repo(MyApp.AnalyticsRepo)
```

## Best Practices

### Testing with Sandbox

Enable in `config/test.exs`:

```elixir
config :my_app, MyApp.Repo,
  pool: Ecto.Adapters.SQL.Sandbox
```

For concurrent tests (PostgreSQL only):

```elixir
# In test_helper.exs
Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, :manual)

# In individual tests
setup do
  pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MyApp.Repo)
  on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  :ok
end
```

**Important:** MySQL does not support concurrent sandbox tests; use `:shared` mode instead.

### Avoiding Deadlocks

Use unique test data rather than shared fixtures:

```elixir
def insert_user do
  MyApp.Repo.insert!(%User{
    email: "user-#{System.unique_integer([:positive])}@test.com"
  })
end
```

### Upserts

Insert with conflict handling:

```elixir
# Replace on conflict
MyRepo.insert(%User{id: 1, name: "Alice"},
  on_conflict: :replace_all,
  conflict_target: :id
)

# Do nothing on conflict
MyRepo.insert(%User{id: 1, name: "Bob"},
  on_conflict: :nothing,
  conflict_target: :id
)

# Custom update on conflict
MyRepo.insert(%User{id: 1, name: "Charlie"},
  on_conflict: [set: [name: "Charlie", updated_at: DateTime.utc_now()]],
  conflict_target: :id
)
```

### Raw Queries

For complex operations, use raw SQL with parameter binding:

```elixir
# Safe parameterized query
MyRepo.query!("SELECT * FROM users WHERE email = $1", [user_email])

# Many results
MyRepo.query_many("COPY users TO STDOUT WITH CSV", [])

# Stream results
MyRepo.stream("SELECT * FROM large_table")
|> Stream.each(&process/1)
|> Stream.run()
```

### Telemetry Integration

Monitor queries and performance:

```elixir
:telemetry.attach(
  "my_app_repo_logging",
  [:my_app, :repo, :query],
  &MyApp.Telemetry.handle_repo_event/4,
  nil
)
```

Events include:

- `:queue_time` — Time waiting for connection
- `:query_time` — Time executing SQL
- `:decode_time` — Time parsing results
- `:idle_time` — Pool idle time

---

**Version:** 3.13.5  
**Source:** [hexdocs.pm/ecto_sql](https://hexdocs.pm/ecto_sql/)  
**Generated:** 2026-04-25
