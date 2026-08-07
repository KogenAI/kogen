# ecto

Ecto is a database abstraction library for Elixir that provides a unified API across different database systems. It offers standardized abstractions for communicating with databases while maintaining type safety and enabling flexible query composition.

Ecto serves three main purposes: it maps external data sources (database tables, APIs, forms) into Elixir structs through schemas; it validates and transforms data through changesets; and it provides a powerful query builder for composing complex database queries in pure Elixir code.

The library is designed to work with any database backend through adapters (like Postgrex for PostgreSQL), allowing developers to write database-agnostic code while leveraging database-specific features when needed.

## Quick Start

Add Ecto and a database driver (e.g., Postgrex for PostgreSQL) to your `mix.exs`:

```elixir
defp deps do
  [
    {:ecto_sql, "~> 3.14"},
    {:postgrex, ">= 0.0.0"}
  ]
end
```

Create a repository module to handle database interactions:

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.Postgres
end
```

Define a schema to map data:

```elixir
defmodule MyApp.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :name, :string
    field :email, :string
    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :email])
    |> validate_required([:name, :email])
  end
end
```

Basic CRUD operations use the repository with changesets:

```elixir
# Create
{:ok, user} = MyApp.Repo.insert(MyApp.User.changeset(%MyApp.User{}, %{name: "Jane", email: "jane@example.com"}))

# Read
user = MyApp.Repo.get(MyApp.User, 1)
users = MyApp.Repo.all(MyApp.User)

# Update
{:ok, user} = MyApp.Repo.update(MyApp.User.changeset(user, %{name: "John"}))

# Delete
MyApp.Repo.delete(user)
```

## Documentation Sections

- [Schemas and Changesets](ecto-3.14.1-schemas.md)
- [Querying and Query Composition](ecto-3.14.1-queries.md)
- [Constraints and Data Integrity](ecto-3.14.1-constraints.md)
- [Embedded Schemas and Nested Data](ecto-3.14.1-embedded.md)
- [Schemaless Operations](ecto-3.14.1-schemaless.md)
- [Multi-Tenancy Patterns](ecto-3.14.1-multitenancy.md)
- [Testing Strategies](ecto-3.14.1-testing.md)

---

**Version:** 3.14.1
**Source:** [hexdocs.pm/ecto](https://hexdocs.pm/ecto/3.14.1)
**Generated:** 2026-08-07
