# ecto_sql

Ecto SQL provides database abstraction and query building for SQL databases in Elixir. It supports PostgreSQL, MySQL, and SQL Server through built-in adapters while enabling custom adapter development using the DBConnection library for pooling and connection handling.

## Quick Start

**Repository Configuration:**

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres
end
```

**Environment Setup:**

```elixir
config :my_app, MyApp.Repo,
  database: "my_app_dev",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5432
```

**Basic Migration:**

```elixir
defmodule MyApp.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table("users") do
      add :name, :string, size: 255
      add :email, :string, unique: true
      add :active, :boolean, default: true
      timestamps()
    end
  end
end
```

## Core Concepts

**Adapters:** Ecto SQL supports Postgres (`Ecto.Adapters.Postgres`), MySQL (`Ecto.Adapters.MyXQL`), and SQL Server (`Ecto.Adapters.Tds`). Each adapter requires a driver option (e.g., `:postgrex` for Postgres).

**Query Execution:**

- `query/4` and `query!/4` - Execute single SQL queries with parameters
- `query_many/4` and `query_many!/4` - Execute multiple statements
- `stream/4` - Return enumerable result sets for memory-efficient processing
- `explain/4` - Generate query execution plans with adapter-specific formatting

**Repository Operations:**

- **Read**: `all/2`, `get/3`, `one/2`, `aggregate/3`, `stream/2`, `exists?/2`
- **Write**: `insert/2`, `update/2`, `delete/2`, `insert_all/3`, `update_all/3`
- **Transactions**: `transact/2`, `in_transaction?/0`, `rollback/1`
- **Loading**: `preload/3` for association loading, `reload/2` to refresh data

**Changesets:** Validate and prepare data for persistence using changeset patterns. Changesets track changes, validations, and constraints before committing to the database.

## Configuration

**Repository Options:**

- `:otp_app` - Application name (required)
- `:adapter` - Database adapter (required)
- `:log` - Control query logging (true/false)
- `:timeout` - Set execution timeout (default: 15000ms, accepts `:infinity`)
- `:max_rows` - Configure streaming batch size

**Migration Options:**

- `:migration_source` - Custom table name for tracking migrations (default: "schema_migrations")
- `:migration_lock` - Concurrency control via advisory locking (default: enabled)
- `:migration_primary_key` - Customize primary key structure
- `:migration_timestamps` - Configure timestamp column names and types

**Index Configurations:**

- `unique: true` - Create unique indexes
- `where: "condition"` - Partial indexes (PostgreSQL)
- `concurrently: true` - Non-blocking index creation (PostgreSQL)
- `include: [:col1, :col2]` - Covering indexes (PostgreSQL)

**Field Types:** `:string` (default 255 chars, configurable with `:size`), `:binary`, `:integer`, `:float`, `:decimal`, `:boolean`, `:datetime_utc`, `:date`, `:time`, `:uuid`, `:map`, `:array`.

## Best Practices

**Migration Patterns:**

- Use `change/0` for reversible migrations instead of separate `up/0` and `down/0` callbacks
- Use `flush()` to guarantee intermediate changes execute before continuing
- Not all operations are reversible (e.g., dropping columns); use `up/0` and `down/0` for those
- PostgreSQL runs migrations in transactions; MySQL does not

**Query Optimization:**

- Use `exists?/2` for simple existence checks instead of `all/2`
- Use `stream/2` for large result sets to avoid memory bloat
- Use `preload/3` to load associations efficiently, avoiding N+1 queries
- Use `to_sql/3` to convert Ecto queries to SQL strings for inspection
- Use `aggregate/3` for count, sum, avg, min, max operations

**Transaction Handling:**

- Use `transact/2` for reliable multi-step operations (recommended over deprecated `transaction/2`)
- Use `Ecto.Multi` to compose complex operations with rollback guarantees
- Call `rollback/1` within transactions to explicitly abort with values
- Check `in_transaction?/0` to understand current transaction state

**Schema Management:**

- Use `mix ecto.gen.migration` to generate timestamped migration files
- Use `mix ecto.migrate` and `mix ecto.rollback` for version control
- Use `mix ecto.load` and `mix ecto.dump` to handle existing schemas reproducibly
- Use `table_exists?/3` to check table presence in current schema

**Testing Setup:**

- Use SQL sandbox wrapper for isolated concurrent test execution
- Configure test database with sandbox mode to run tests in transactions
- Each test runs in a separate transaction, enabling parallel test execution without conflicts

**Bulk Operations:**

- Use `insert_all/3` for bulk inserts with optional conflict handling via `:on_conflict`
- Use `update_all/3` for batch updates with query filtering
- Use `:on_conflict` with `:replace_all` or `:replace` for upsert patterns

**Error Handling:**

- Changesets provide detailed validation error messages before database execution
- Use `changeset.valid?` to check validity before calling database functions
- Capture exceptions from `!` versions (e.g., `insert!`) to handle database constraints

---

**Version:** 3.13.2
**Source:** [hexdocs.pm/ecto_sql](https://hexdocs.pm/ecto_sql/)
**Generated:** 2025-10-28
