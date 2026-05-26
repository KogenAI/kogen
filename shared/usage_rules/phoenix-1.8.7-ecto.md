# Phoenix - Ecto & Database Layer

## Overview

Ecto is Elixir's primary tool for data validation and database persistence. Phoenix projects include Ecto with PostgreSQL by default, though support exists for MySQL, MSSQL, SQLite3, and ETS. Ecto separates data validation from persistence, enabling consistent data handling across different storage backends.

## Schema Definition

Generate database schemas using `phx.gen.schema`:

```bash
mix phx.gen.schema User users name:string email:string age:integer
```

This creates both a schema module and migration. Schema modules define the structure and relationships:

```elixir
defmodule MyApp.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :name, :string
    field :email, :string
    field :age, :integer
    has_many :posts, MyApp.Post

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

## Field Types

Common Ecto field types:

- `:string` — Text up to 255 characters
- `:text` — Arbitrary text length
- `:integer` — 32-bit integers
- `:bigint` — 64-bit integers
- `:float` — Floating point numbers
- `:boolean` — True/false
- `:date` — YYYY-MM-DD dates
- `:time` — HH:MM:SS times
- `:datetime` — Date and time with timezone
- `:naive_datetime` — Date and time without timezone
- `:uuid` — UUID identifiers
- `:binary` — Binary data
- `:map` — JSON/JSONB data structures
- `:array` — Lists of values (type `:array, :string`)

## Changesets

Changesets define transformation pipelines for data. The typical pattern includes:

1. **Cast** — Accept parameters and strip unintended fields
2. **Validate** — Check data constraints
3. **Persist** — Save to database

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:name, :email, :password])
  |> validate_required([:name, :email])
  |> validate_length(:password, min: 8)
  |> validate_format(:email, ~r/@/)
  |> validate_exclusion(:email, ["admin@example.com"])
  |> unique_constraint(:email)
  |> hash_password()
end

defp hash_password(changeset) do
  case changeset do
    %Ecto.Changeset{valid?: true, changes: %{password: password}} ->
      put_change(changeset, :password, hash(password))
    _ ->
      changeset
  end
end
```

## Validation Functions

Common validation helpers:

```elixir
validate_required(changeset, [:field1, :field2])
validate_length(changeset, :name, min: 3, max: 100)
validate_format(changeset, :email, ~r/@/)
validate_number(changeset, :age, greater_than_or_equal_to: 0)
validate_inclusion(changeset, :status, ["active", "inactive"])
validate_exclusion(changeset, :username, ["admin", "root"])
validate_confirmation(changeset, :password)
unique_constraint(changeset, :email)
foreign_key_constraint(changeset, :user_id)
```

Parameters not in the cast list are automatically stripped, preventing injection attacks.

## Migrations

Generate migrations with `ecto.gen.migration`:

```bash
mix ecto.gen.migration create_users
```

Migrations define schema changes:

```elixir
defmodule MyApp.Repo.Migrations.CreateUsers do
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

Common operations:

```elixir
create table(:posts) do
  add :title, :string
  add :body, :text
  add :user_id, references(:users)
  timestamps()
end

alter table(:users) do
  add :bio, :text
  modify :email, :string, null: false
  remove :age
end

create unique_index(:users, [:email])
create index(:posts, [:user_id])
drop table(:old_table)
```

Run migrations with `mix ecto.migrate` and rollback with `mix ecto.rollback`.

## Repository Operations

The `Repo` module provides the interface for persistence:

```elixir
# Insert
{:ok, user} = Repo.insert(%User{name: "John", email: "john@example.com"})

# Query
user = Repo.get(User, id)
users = Repo.all(User)

# Update
changeset = User.changeset(user, %{name: "Jane"})
{:ok, updated_user} = Repo.update(changeset)

# Delete
Repo.delete(user)

# Bulk operations
Repo.insert_all(User, [
  %{name: "User1", email: "user1@example.com"},
  %{name: "User2", email: "user2@example.com"}
])

Repo.update_all(User, set: [active: false])
Repo.delete_all(User)
```

## Query DSL

Build safe, composable queries:

```elixir
from(u in User, where: u.active == true, select: u.email)
|> Repo.all()

# With patterns
User
|> where(active: true)
|> where([u], u.age > 18)
|> order_by(desc: :created_at)
|> limit(10)
|> Repo.all()

# Joins
from(u in User,
  join: p in assoc(u, :posts),
  where: p.published == true,
  select: u)
|> Repo.all()

# Count and aggregates
from(u in User, select: count(u.id))
|> Repo.one()

from(p in Post, select: avg(p.views))
|> Repo.one()
```

## Associations

Define relationships between schemas:

```elixir
# One-to-many
has_many :posts, MyApp.Post
has_many :comments, through: [:posts, :comments]

# Belongs to
belongs_to :user, MyApp.User

# Many-to-many
many_to_many :tags, MyApp.Tag, join_through: "post_tags"
```

Load associations with `preload`:

```elixir
user = Repo.get(User, 1)
user_with_posts = Repo.preload(user, :posts)

users = Repo.all(from(u in User, preload: :posts))
```

## Essential Mix Tasks

- `mix ecto.create` — Create the database
- `mix ecto.drop` — Drop the database
- `mix ecto.migrate` — Run migrations
- `mix ecto.rollback` — Undo migrations
- `mix ecto.gen.migration name` — Generate a new migration
- `mix ecto.gen.schema Model table` — Generate schema and migration

---

[← Back to main](phoenix-1.8.7.md)
**Version:** 1.8.7
