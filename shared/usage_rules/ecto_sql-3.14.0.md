# ecto_sql

Ecto SQL provides the SQL adapter building blocks for Ecto, an Elixir database library and query language. It includes default implementations for PostgreSQL, MySQL, and MSSQL databases, along with tools for database migrations, schema management, and testing.

## Quick Start

### Installation

Add ecto_sql to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:ecto_sql, "~> 3.14"}
  ]
end
```

Run `mix deps.get` to install.

### Basic Repository Setup

Create a repository module to interact with your database:

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.Postgres
end
```

Configure your database in `config/config.exs`:

```elixir
config :my_app, MyApp.Repo,
  database: "my_app_db",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5432
```

### Create and Run Migrations

Generate a new migration:

```bash
mix ecto.gen.migration create_users
```

Edit the generated migration file in `priv/repo/migrations/`:

```elixir
defmodule MyApp.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :name, :string, null: false
      add :email, :string, unique: true
      add :age, :integer

      timestamps()
    end
  end
end
```

Run migrations:

```bash
mix ecto.migrate
```

## Core Concepts

### SQL Adapters

Ecto SQL adapts to specific database systems through the `Ecto.Adapters.SQL` module. Each adapter (Postgres, MySQL, MSSQL) implements SQL generation, type mapping, and database-specific features. Select your adapter in the repository configuration using `adapter: Ecto.Adapters.Postgres`, `Ecto.Adapters.MySQL`, or `Ecto.Adapters.MSSQL`.

### Migrations

Migrations are timestamped Elixir files that track schema changes. Each migration defines a `change/0` callback with operations like `create table`, `add column`, `modify column`, and `drop table`. Forward and rollback logic is automatically derived from `change/0`, or you can manually define `up/0` and `down/0` for complex operations.

### Schema and Changesets

Schemas define your data structure as Elixir structs. Use changesets to validate and track data changes:

```elixir
defmodule MyApp.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :name, :string
    field :email, :string
    field :age, :integer

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :email, :age])
    |> validate_required([:name, :email])
    |> unique_constraint(:email)
  end
end
```

### Query Operations

Use the repository to query and persist data:

```elixir
# Insert
MyApp.Repo.insert(%MyApp.User{name: "Alice", email: "alice@example.com"})

# Query
user = MyApp.Repo.get(MyApp.User, 1)
users = MyApp.Repo.all(MyApp.User)

# Update
MyApp.Repo.update(changeset)

# Delete
MyApp.Repo.delete(user)
```

### Test Sandbox

Ecto SQL provides a test sandbox for running tests concurrently with automatic transaction rollback:

```elixir
setup do
  :ok = Ecto.Adapters.SQL.Sandbox.checkout(MyApp.Repo)
  Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, {:shared, self()})
  :ok
end
```

## Configuration

### Repository Configuration

Database connection options are set in config files:

```elixir
config :my_app, MyApp.Repo,
  adapter: Ecto.Adapters.Postgres,
  database: "my_app_db",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5432,
  pool_size: 10,
  max_overflow: 5
```

Common options:

- `adapter`: The SQL adapter module (Postgres, MySQL, MSSQL)
- `database`: Database name
- `username`: Database user
- `password`: Database password
- `hostname`: Server address
- `port`: Connection port
- `pool_size`: Number of connections in the pool (default: 10)
- `max_overflow`: Additional connections when pool is exhausted (default: 0)

### Migration Configuration

Migrations can be configured in your repository:

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.Postgres
end
```

Migration files are stored in `priv/repo/migrations/` by default.

### Testing Configuration

For tests, use a separate configuration with database pool mode:

```elixir
config :my_app, MyApp.Repo,
  adapter: Ecto.Adapters.Postgres,
  database: "my_app_test",
  pool: Ecto.Adapters.SQL.Sandbox
```

## Best Practices

### Use Changesets for Validation

Always apply changesets before inserting or updating data. This ensures validation, casts types, and tracks changes:

```elixir
changeset = MyApp.User.changeset(%MyApp.User{}, params)
case MyApp.Repo.insert(changeset) do
  {:ok, user} -> handle_success(user)
  {:error, changeset} -> handle_error(changeset)
end
```

### Manage Database Connections Properly

Use connection pooling and configure appropriate pool sizes based on your application's concurrency needs. Set `pool_size` to the expected number of concurrent connections.

### Test with Real Databases

Prefer integration testing with real databases over mocking SQL. Use the Ecto test sandbox for concurrent test execution with automatic rollback.

### Write Reversible Migrations

Ensure migrations can be rolled back. Avoid irreversible operations like dropping columns with data loss in production. If necessary, split migrations into multiple steps (deprecation, then removal).

### Name Constraints Explicitly

When adding unique constraints or foreign keys, name them explicitly for clarity:

```elixir
create index(:users, [:email], unique: true, name: "users_email_unique")
```

### Use Parameterized Queries

Always use parameterized queries through Ecto to prevent SQL injection. Never concatenate user input into raw SQL strings.

### Monitor Performance

Use `Ecto.Query` fragments carefully—raw SQL fragments bypass Ecto's safety guarantees. Prefer Ecto's query DSL. For performance tuning, examine database query logs and use `EXPLAIN` on slow queries.

---

**Version:** 3.14.0  
**Source:** [hexdocs.pm/ecto_sql](https://hexdocs.pm/ecto_sql)  
**Generated:** 2026-08-07
