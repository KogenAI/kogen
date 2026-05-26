# Phoenix 1.8.1 - Data Modeling with Ecto

## Overview

Ecto is Elixir's primary tool for "data validation and persistence" in Phoenix applications. It supports multiple databases including PostgreSQL, MySQL, MSSQL, SQLite3, and ETS. Ecto provides a type-safe query DSL, migration system, and validation framework for building reliable data layers.

## Core Concepts

**Schemas** are Elixir structs that map data between your application and external sources like databases. Schemas define the structure, types, and relationships of your data.

**Changesets** define transformation pipelines for data validation and type casting. They validate user input before database operations and enable optimized updates by tracking which fields changed.

## Generating Schemas

Use `phx.gen.schema` to create both schema files and migration files:

```bash
# Generate User schema with migration
mix phx.gen.schema User users name:string email:string age:integer

# Without migration (for existing tables)
mix phx.gen.schema User users --no-migration
```

This creates:

- `lib/hello/user.ex` - Schema module
- `priv/repo/migrations/TIMESTAMP_create_users.exs` - Migration file

## Schema Definition

```elixir
defmodule Hello.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :name, :string
    field :email, :string
    field :age, :integer
    field :is_active, :boolean, default: true
    field :inserted_at, :utc_datetime

    has_many :posts, Hello.Post
    belongs_to :company, Hello.Company

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :email, :age])
    |> validate_required([:name, :email])
    |> validate_format(:email, ~r/@/)
    |> unique_constraint(:email)
  end
end
```

## Changesets & Validation

Changesets combine casting and validation:

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:name, :email, :age])
  |> validate_required([:name, :email])
  |> validate_length(:name, min: 2, max: 100)
  |> validate_format(:email, ~r/@/)
  |> validate_inclusion(:role, ["admin", "user"])
  |> unique_constraint(:email)
  |> foreign_key_constraint(:company_id)
end

# In controller
def create(conn, %{"user" => user_params}) do
  changeset = User.changeset(%User{}, user_params)
  case Repo.insert(changeset) do
    {:ok, user} ->
      # Success path
    {:error, changeset} ->
      # Display validation errors
  end
end
```

## Validation Functions

- `validate_required/3` - Ensures fields are present
- `validate_length/3` - Checks string/list length
- `validate_format/3` - Matches regex pattern
- `validate_inclusion/3` - Checks against allowed values
- `validate_number/3` - Validates numeric values
- `unique_constraint/2` - Database uniqueness check
- `foreign_key_constraint/2` - Database foreign key check

## Querying with Ecto

The Query DSL provides type-safe database access:

```elixir
import Ecto.Query

# Simple queries
query = from u in User, where: u.age > 18, select: u
Repo.all(query)

# With joins
from u in User,
  join: p in Post, on: p.user_id == u.id,
  where: p.published == true,
  select: {u.name, p.title}

# Filtered queries
from u in User,
  where: u.email like ^"%@example.com",
  order_by: [desc: u.inserted_at],
  limit: 10
```

## Data Persistence

Basic CRUD operations:

```elixir
# Insert
changeset = User.changeset(%User{}, %{"name" => "John", "email" => "john@example.com"})
{:ok, user} = Repo.insert(changeset)

# Update
changeset = User.changeset(user, %{"age" => 30})
{:ok, updated_user} = Repo.update(changeset)

# Delete
Repo.delete(user)

# Get by primary key
Repo.get(User, 1)

# Get or raise
Repo.get!(User, 1)

# Get by attribute
Repo.get_by(User, email: "john@example.com")
```

## Mix Tasks for Database Management

- `mix ecto.create` — Creates databases specified in config
- `mix ecto.drop` — Drops databases
- `mix ecto.migrate` — Applies pending migrations
- `mix ecto.rollback` — Reverses one migration
- `mix ecto.rollback --all` — Reverses all migrations
- `mix ecto.gen.migration migration_name` — Generates new migration file
- `mix ecto.reset` — Drops, creates, and migrates

## Migrations

Create migration files to evolve schema over time:

```elixir
defmodule Hello.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :name, :string, null: false
      add :email, :string, null: false
      add :age, :integer

      timestamps()
    end

    create unique_index(:users, [:email])
  end
end
```

## Associations

Define relationships between schemas:

```elixir
# One-to-many
defmodule Hello.User do
  schema "users" do
    has_many :posts, Hello.Post
  end
end

defmodule Hello.Post do
  schema "posts" do
    belongs_to :user, Hello.User
  end
end

# Many-to-many
defmodule Hello.User do
  schema "users" do
    many_to_many :roles, Hello.Role, join_through: "user_roles"
  end
end
```

## Best Practices

- Always use changesets for validation before persistence
- Cast only the parameters you explicitly allow (prevents mass-assignment vulnerabilities)
- Use separate changeset functions for different operations (registration vs update)
- Validate at the changeset level, not in migrations or controllers
- Use database constraints for uniqueness and referential integrity
- Keep validation close to the schema definition
- Use migrations for schema evolution, never modify schema files directly
- Preload associations to avoid N+1 queries: `Repo.preload(users, :posts)`
- Use `Ecto.Query` DSL instead of raw SQL for type safety

---

[← Back to main](phoenix-1.8.1.md)
**Version:** 1.8.1
