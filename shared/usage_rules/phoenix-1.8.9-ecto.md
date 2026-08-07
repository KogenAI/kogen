# phoenix - Ecto & Data Modeling

## Overview

Ecto provides data validation and persistence capabilities for Phoenix applications. The framework supports multiple databases including PostgreSQL, MySQL, MSSQL, ETS, and SQLite3, with PostgreSQL as the default for new projects. Ecto emphasizes compile-time safety, SQL injection protection, and explicit data transformation pipelines.

## Architecture

**Schemas** map Elixir data types to external data sources. They define your domain model:

```elixir
defmodule Hello.Blog.Post do
  use Ecto.Schema
  import Ecto.Changeset

  schema "posts" do
    field :title, :string
    field :body, :string
    field :author_id, :integer

    timestamps()
  end
end
```

**Changesets** establish transformation pipelines for data before use. They handle validation, casting, and tracking changes:

```elixir
def changeset(post, attrs) do
  post
  |> cast(attrs, [:title, :body])
  |> validate_required([:title, :body])
  |> validate_length(:title, min: 3, max: 100)
end
```

**Repository (Repo)** serves as the interface for database operations. The `Hello.Repo` module manages queries, persistence, and connection pooling:

```elixir
Repo.insert(changeset)
Repo.update(changeset)
Repo.delete(post)
Repo.get(Post, 123)
```

## Defining Schemas

Field types supported by Ecto:

```elixir
schema "posts" do
  field :title, :string
  field :body, :text
  field :published, :boolean, default: false
  field :views, :integer, default: 0
  field :rating, :float
  field :featured_at, :naive_datetime
  field :created_at, :utc_datetime

  belongs_to :user, User
  has_many :comments, Comment
  many_to_many :tags, Tag, join_through: "posts_tags"

  timestamps()
end
```

**Relationships:**

- `belongs_to` - foreign key relationship
- `has_one` - one-to-one relationship
- `has_many` - one-to-many relationship
- `many_to_many` - many-to-many through join table

The `timestamps()` macro adds `inserted_at` and `updated_at` fields automatically.

## Changesets

Changesets define pipelines for data transformation. Always use changesets for persistence:

```elixir
def changeset(post, attrs) do
  post
  |> cast(attrs, [:title, :body, :author_id])
  |> validate_required([:title, :body])
  |> validate_length(:body, min: 10)
  |> validate_format(:email, ~r/@/)
  |> unique_constraint(:email)
  |> assoc_constraint(:author)
end
```

**cast/3** whitelists fields from user input:

```elixir
cast(post, attrs, [:title, :body])
```

This prevents mass assignment of unexpected fields.

**Validations** ensure data integrity:

```elixir
validate_required([:title, :body])
validate_length(:title, min: 3, max: 100)
validate_format(:email, ~r/@/)
validate_number(:age, greater_than: 0, less_than: 150)
validate_inclusion(:status, ["draft", "published"])
validate_confirmation(:password, message: "passwords do not match")
```

**Database constraints** prevent invalid states:

```elixir
unique_constraint(:email, message: "email already exists")
foreign_key_constraint(:user_id, message: "invalid user")
assoc_constraint(:user, message: "user must exist")
```

## CRUD Operations

**Create:**

```elixir
attrs = %{"title" => "My Post", "body" => "Content"}
Post.changeset(%Post{}, attrs)
|> Repo.insert()

# Returns {:ok, post} or {:error, changeset}
```

**Read:**

```elixir
Repo.get(Post, 123)                    # By primary key
Repo.get_by(Post, slug: "my-post")     # By field
Repo.all(Post)                         # All records
```

**Update:**

```elixir
post
|> Post.changeset(%{"title" => "Updated"})
|> Repo.update()
```

**Delete:**

```elixir
Repo.delete(post)
```

## Queries

Build queries using Ecto's query DSL:

```elixir
from p in Post,
  where: p.published == true,
  where: p.inserted_at > ^DateTime.add(DateTime.utc_now(), -30, :day),
  order_by: [desc: p.created_at],
  limit: 10
|> Repo.all()
```

**Common patterns:**

```elixir
# Filter
from p in Post, where: p.author_id == ^user_id

# Relationships
from p in Post,
  join: u in assoc(p, :user),
  select: {p, u}

# Preload
Post
|> Repo.all()
|> Repo.preload(:comments)

# Aggregation
from p in Post, select: count(p.id)
```

## Migrations

Create and manage database schema with migrations:

```bash
mix ecto.gen.migration create_posts
```

Edit the generated migration file:

```elixir
def change do
  create table(:posts) do
    add :title, :string, null: false
    add :body, :text
    add :author_id, references(:users), null: false

    timestamps()
  end

  create index(:posts, [:author_id])
end
```

Apply migrations:

```bash
mix ecto.create      # Create database
mix ecto.migrate     # Apply pending migrations
mix ecto.rollback    # Undo last migration
```

## Common Mix Tasks

- `mix ecto.create` — Initialize databases
- `mix ecto.migrate` — Apply pending schema changes
- `mix ecto.rollback` — Reverse migrations
- `mix ecto.gen.migration` — Create custom migrations
- `mix phx.gen.schema` — Generate schema and migration
- `mix phx.gen.context` — Generate full CRUD context module

## Preloading and Eager Loading

Prevent N+1 queries by preloading associations:

```elixir
# Lazy loading (causes N+1 queries)
posts = Repo.all(Post)
posts |> Enum.map(&(&1.author))

# Eager loading
posts = Repo.all(Post) |> Repo.preload(:author)

# In queries
from p in Post, preload: :author
```

## Best Practices

- **Always use changesets**: Never insert raw data into the database
- **Whitelist fields with cast**: Prevent mass assignment vulnerabilities
- **Validate at boundaries**: Validate user input in changesets
- **Use constraints**: Leverage database constraints for data integrity
- **Preload associations**: Avoid N+1 query problems
- **Organize by context**: Group related schemas and queries in modules
- **Test changesets**: Unit test validation logic separately from persistence

---

[← Back to main](phoenix-1.8.9.md)
**Version:** 1.8.9
