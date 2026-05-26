# ash_postgres

AshPostgres is a PostgreSQL data layer for Ash Framework, providing automatic SQL generation, migrations, and database persistence while keeping your code independent of the specific data storage implementation.

## Quick Start

### Installation

Use Igniter for streamlined setup:

```bash
mix igniter.install ash_postgres
```

Or manually add to `mix.exs`:

```elixir
{:ash_postgres, "~> 2.6"}
```

Update `.formatter.exs` to include `:ash_postgres` in `import_deps`.

### Repository Configuration

Create `lib/app/repo.ex`:

```elixir
defmodule App.Repo do
  use AshPostgres.Repo, otp_app: :app

  def installed_extensions do
    ["ash-functions"]
  end
end
```

Configure in `config/dev.exs`:

```elixir
config :app, App.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "app_dev",
  show_sensitive_data_on_error?: true,
  pool_size: 10
```

Add repo to supervision tree in `lib/app/application.ex`.

### Enable on Resources

```elixir
use Ash.Resource,
  domain: App.Domain,
  data_layer: AshPostgres.DataLayer

postgres do
  table "tickets"
  repo App.Repo
end
```

## Core Concepts

### Automatic Schema Inference

AshPostgres generates SQL from Ash resource definitions. Define attributes, relationships, and validations once—AshPostgres creates matching database schemas automatically.

### Code-First Migrations

Compare resource snapshots to auto-generate migrations:

```bash
mix ash.codegen --dev          # Generate temporary dev migrations
mix ash.migrate                # Apply migrations
mix ash.codegen add_feature    # Named migration consolidating dev changes
```

This eliminates manual migration writing during development.

### Aggregates

Retrieve grouped relationship counts/sums directly in queries:

```elixir
aggregates do
  count :total_tickets, :tickets
  count :open_tickets, :tickets do
    filter expr(status == :open)
  end
end
```

Aggregates compile to efficient SQL—use in filters and sorts.

### Calculations

Derive computed values from aggregates:

```elixir
calculations do
  calculate :percent_open, :float,
    expr(open_tickets / total_tickets)
end
```

### Relationships

Define relationships in resources; AshPostgres creates foreign keys automatically:

```elixir
relationships do
  has_many :tickets, Ticket do
    source_attribute :id
    destination_attribute :assignee_id
  end
end
```

## Configuration

### Environment-Specific Configs

- **config/config.exs**: Reference domains and repos
- **config/dev.exs**: Local Postgres credentials
- **config/test.exs**: Sandboxed test database
- **config/runtime.exs**: Production via `DATABASE_URL` environment variable

### Foreign Key Behavior

Control foreign key constraints via `references` in postgres block:

```elixir
postgres do
  table "tickets"

  references do
    reference :assignee_id, on_delete: :nilify, on_update: :update
  end
end
```

**On Delete/Update options**:

- `:restrict` – Prevent changes immediately
- `:nothing` – Defer constraint check to transaction end
- `:delete` – Cascade delete
- `:nilify` – Clear foreign key columns
- `{:nilify, [:column]}` – Selectively clear columns (PostgreSQL 15+)

**Critical**: Foreign key operations bypass Ash authorization, validations, and notifications—they run at database level only.

### Extensions

Enable PostgreSQL extensions via `installed_extensions/0`:

```elixir
def installed_extensions do
  ["uuid-ossp", "ash-functions"]
end
```

Can be strings (standard extensions) or modules implementing `AshPostgres.CustomExtension`.

### Multitenancy

Use PostgreSQL schemas for schema-based multitenancy. Define `all_tenants/0` in repo for tenant migrations.

## Best Practices

### Development Workflow

1. Modify resource definitions (attributes, relationships, validations)
2. Run `mix ash.codegen --dev` to generate temporary migrations
3. Apply with `mix ash.migrate`
4. Repeat until feature complete
5. Run `mix ash.codegen add_feature_name` to consolidate into named migration
6. Execute final migration with `mix ash.migrate`

### Production Releases

For applications without Mix access, create a Release module:

```elixir
defmodule App.Release do
  def migrate, do: Ash.migrate(repo: [App.Repo])
  def rollback(repo, version), do: Ash.rollback(repo: [App.Repo], to: version)
end
```

### Query Patterns

Combine filters, aggregates, and calculations for powerful queries:

```elixir
Ticket
|> Ash.Query.filter(contains(subject, "2"))
|> Ash.Query.select([:id, :subject, :total_tickets, :percent_open])
|> Ash.read!()
```

### Design Philosophy

Code runs identically whether backed by ETS or PostgreSQL. Use AshPostgres to add persistence without coupling business logic to a specific data layer.

---

**Version:** 2.6.18
**Source:** https://hexdocs.pm/ash_postgres/
**Generated:** 2025-10-28
