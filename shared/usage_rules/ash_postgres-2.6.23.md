# ash_postgres

AshPostgres is an Ash extension that maps Elixir resources to PostgreSQL database tables. It provides automatic SQL generation, migration management, and tight integration with Ash's resource-driven development model.

## Quick Start

### Installation

Use Igniter for guided setup:

```bash
mix igniter.install ash_postgres
```

Or manually add to `mix.exs`:

```elixir
{:ash_postgres, "~> 2.6.0"}
```

Update `.formatter.exs` to include AshPostgres in the `import_deps` list.

### Basic Resource Configuration

Create a repository module wrapping `Ecto.Repo`:

```elixir
defmodule MyApp.Repo do
  use AshPostgres.Repo, otp_app: :my_app
end
```

Configure in `config/config.exs`:

```elixir
config :my_app, MyApp.Repo, adapter: Ecto.Adapters.Postgres
```

For each environment (dev, test, prod), add connection settings to `config/dev.exs`, `config/test.exs`, or `config/runtime.exs`:

```elixir
config :my_app, MyApp.Repo,
  username: "postgres",
  password: "postgres",
  database: "my_app_dev",
  hostname: "localhost"
```

Define resources with table mapping:

```elixir
defmodule MyApp.Ticket do
  use Ash.Resource, data_layer: AshPostgres.DataLayer

  postgres do
    table "tickets"
    repo MyApp.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string
    attribute :status, :string
  end
end
```

### Initial Setup

Generate and apply migrations:

```bash
mix ash.codegen
mix ash.setup
```

## Core Concepts

### Automatic SQL Generation

AshPostgres automatically translates Ash queries to SQL. Code written for ETS-backed resources works identically—the framework handles SQL generation internally. This eliminates manual query writing for standard operations.

### Aggregates and Calculations

Aggregates enable querying grouped relationship data and are translated directly to SQL:

```elixir
# Add aggregate to resource
aggregates do
  count :ticket_count, :tickets
end
```

Aggregates work in filters and sorts, enabling powerful queries without raw SQL.

### Table Configuration

The basic configuration requires:

- `AshPostgres.postgres.table` - The PostgreSQL table name
- `AshPostgres.postgres.repo` - The repository module to use

### Migration Workflow

**Development Phase**: Use the `--dev` flag for rapid iteration without naming migrations:

```bash
mix ash.codegen --dev
mix ash.migrate
```

**Finalization**: When ready, name the final migration:

```bash
mix ash.codegen add_feature_name
```

This consolidates dev migrations into clean, named files.

### Database Features

- **Check Constraints**: Define validation rules at the database level
- **Custom Indexes**: Add performance indexes beyond defaults
- **Foreign Keys**: Configure cascade behavior for relationships
- **Postgres Schemas**: Use native schemas for multitenancy
- **Polymorphic Resources**: Map polymorphic types to database structures

## Configuration

### Repository Setup

Create a custom repo module to centralize database configuration:

```elixir
defmodule MyApp.Repo do
  use AshPostgres.Repo, otp_app: :my_app

  def all_tenants do
    # Required for schema-based multitenancy
    [:tenant_a, :tenant_b]
  end
end
```

### Environment-Specific Configuration

Use `config/runtime.exs` for runtime configuration (recommended for production):

```elixir
config :my_app, MyApp.Repo,
  url: System.get_env("DATABASE_URL"),
  ssl: true,
  ssl_opts: [verify: :verify_none]
```

### Multitenancy

For schema-based multitenancy, define `all_tenants/0` in the repo module. AshPostgres handles tenant-specific migrations automatically:

```bash
mix ash_postgres.migrate --tenants
```

## Best Practices

### Migration Management

1. **Use `--dev` workflow during development** - Avoids naming friction and keeps migration history clean
2. **Name migrations descriptively** - Use `mix ash.codegen descriptive_name` for final migrations
3. **For released apps**, create a `MyApp.Release` module for production migrations:
   ```elixir
   def migrate do
     Ecto.Migrator.run(MyApp.Repo, :up, all: true)
   end
   ```
4. **Test migrations** before production deployment

### Query Optimization

- **Leverage aggregates** instead of fetching and counting in application code
- **Use filters on aggregates** to reduce result sets
- **Index frequently filtered columns** - AshPostgres generates indexes automatically
- **Rely on automatic SQL generation** rather than raw queries

### Production Deployment

- Use `config/runtime.exs` for all environment-dependent settings
- Handle database creation/migration in release tasks
- For schema-based multitenancy, ensure `all_tenants/0` returns correct tenant list
- Test rollback procedures with `mix ash_postgres.rollback --version X`

### Development Workflow

1. Modify resources as requirements change
2. Run `mix ash.codegen --dev` to generate temporary migrations
3. Execute `mix ash.migrate` to test changes
4. Repeat until satisfied
5. Run `mix ash.codegen feature_name` to finalize

### Existing Database Integration

AshPostgres can generate resources from existing databases via scaffolding tools, eliminating manual resource definition for legacy systems.

---

**Version:** 2.6.23
**Source:** [hexdocs.pm/ash_postgres](https://hexdocs.pm/ash_postgres/)
**Generated:** 2025-11-04
