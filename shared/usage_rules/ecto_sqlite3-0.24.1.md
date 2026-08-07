# ecto_sqlite3

An Ecto SQLite3 adapter that provides seamless integration between Ecto (Elixir's database toolkit) and SQLite3 databases using Exqlite as the underlying driver.

## Quick Start

### Installation

Add ecto_sqlite3 to your `mix.exs` dependencies:

```elixir
defp deps do
  [
    {:ecto_sqlite3, "~> 0.24"}
  ]
end
```

Then run `mix deps.get`.

### Basic Setup

Create a repository module in your application:

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.SQLite3
end
```

Configure the repository in `config/config.exs`:

```elixir
config :my_app,
  ecto_repos: [MyApp.Repo]

config :my_app, MyApp.Repo,
  database: "priv/repo/myapp.db"
```

Add your Repo to your application's supervisor tree in `lib/my_app/application.ex`:

```elixir
children = [
  MyApp.Repo,
  # ... other children
]

Supervisor.start_link(children, strategy: :one_for_one)
```

## Core Concepts

### Ecto Schemas and Migrations

Define schemas as normal Ecto patterns. SQLite3 migration support includes standard operations like creating tables, adding columns, and managing indexes.

### Type Support

SQLite3 in Ecto supports core types: `:string`, `:integer`, `:float`, `:boolean`, `:binary`, `:date`, `:time`, `:datetime`, `:decimal`, and `:text`. Handle type conversions appropriately for your SQLite database constraints.

### Custom Type Extensions

Use the `Ecto.Adapters.SQLite3.TypeExtension` behavior to map custom Elixir data types through encoder/decoder functions, enabling specialized data handling beyond standard types.

### Transaction Semantics

SQLite3 transactions follow standard Ecto transaction patterns via `Repo.transaction/2`. Nested transactions use savepoints; isolation levels are limited to SQLite's capabilities.

## Configuration

### Core Options

- **`:database`** (required) — File path to the SQLite database file. Use relative paths like `"priv/repo/app.db"` or absolute paths.
- **`:journal_mode`** — Sets SQLite's journal mode (`:wal`, `:delete`, etc.). WAL mode improves concurrency for read-heavy workloads.
- **`:cache_size`** — Database page cache size in pages (positive for KiB, negative for pages).
- **`:timeout`** — Connection timeout in milliseconds.

### Database Encryption

Enable SQLCipher or official SEE encryption:

```elixir
config :my_app, MyApp.Repo,
  database: "priv/repo/encrypted.db",
  key: "your-encryption-key"
```

For system-managed encryption, set compile-time environment variables before building:

- `EXQLITE_USE_SYSTEM` — Use system SQLite with custom flags
- `EXQLITE_SYSTEM_CFLAGS` — Custom C compiler flags
- `EXQLITE_SYSTEM_LDFLAGS` — Custom linker flags

### Pool Configuration

Configure connection pooling:

```elixir
config :my_app, MyApp.Repo,
  database: "priv/repo/app.db",
  pool_size: 5,
  queue_target: 5000
```

SQLite supports limited concurrency; smaller pool sizes (1-5) often work best.

## Best Practices

### Development and Testing

1. **Use separate databases** — Maintain distinct SQLite files for development, testing, and production to avoid conflicts.
2. **Version control** — Exclude `.db` files from version control; track schema changes via migrations only.

### Performance Optimization

1. **Journal Mode** — Use WAL mode for improved read concurrency in production deployments:

   ```elixir
   config :my_app, MyApp.Repo,
     journal_mode: :wal
   ```

2. **Indexing** — Create targeted indexes on frequently queried columns to improve query performance.

3. **Pool Size** — Keep pool size conservative (2-5 connections) since SQLite has inherent write concurrency limits.

4. **Batch Operations** — Group multiple operations into transactions for efficiency:
   ```elixir
   Repo.transaction(fn ->
     Enum.each(records, &Repo.insert/1)
   end)
   ```

### Data Integrity

1. **Type Enforcement** — SQLite has limited type enforcement; rely on Ecto schema definitions and validation.
2. **Foreign Keys** — Enable foreign key constraints in migrations if referential integrity is critical.
3. **Transactions** — Use transactions for multi-step operations requiring atomicity.

### Deployment Considerations

1. **File Permissions** — Ensure the SQLite database directory has appropriate read/write permissions.
2. **Backups** — Implement regular SQLite database file backups; use `.db-wal` and `.db-shm` files if WAL mode is enabled.
3. **Scalability** — SQLite is optimized for single-server deployments. For distributed systems requiring replication, evaluate PostgreSQL or MySQL.

### Testing

Run unit tests normally:

```bash
mix test
```

For full integration tests requiring SQLite bindings:

```bash
EXQLITE_INTEGRATION=true mix test
```

---

**Version:** 0.24.1
**Source:** [github.com/elixir-sqlite/ecto_sqlite3](https://github.com/elixir-sqlite/ecto_sqlite3)
**Generated:** 2026-08-07
