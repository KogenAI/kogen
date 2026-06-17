# phoenix - Database & Ecto Integration

## Overview

Ecto is the Elixir ecosystem's solution for data validation and persistence. Phoenix includes built-in support for multiple databases through Ecto adapters including PostgreSQL (default), MySQL, MSSQL, SQLite3, and ETS.

Ecto provides three main components: Schemas (maps Elixir structures to data sources), Changesets (handle data transformation and validation), and Repositories (manage database connections and queries).

## Database Setup

### Creating and Managing Databases

```bash
# Create the database
mix ecto.create

# Run pending migrations
mix ecto.migrate

# Rollback the last migration
mix ecto.rollback

# Create a new migration file
mix ecto.gen.migration create_posts
```

Configure the database in `config/dev.exs`:

```elixir
config :hello, Hello.Repo,
  username: "postgres",
  password: "postgres",
  database: "hello_dev",
  hostname: "localhost",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10
```

## Schemas

Ecto schemas map Elixir data structures to external sources like database tables. Use the `phx.gen.schema` generator to create both schema files and corresponding database migrations:

```bash
mix phx.gen.schema Post posts title:string body:text published_at:naive_datetime
```

This generates:

```elixir
defmodule Hello.Post do
  use Ecto.Schema
  import Ecto.Changeset

  schema "posts" do
    field :title, :string
    field :body, :string
    field :published_at, :naive_datetime

    timestamps()
  end

  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body, :published_at])
    |> validate_required([:title, :body])
    |> validate_length(:title, min: 1, max: 255)
  end
end
```

### Field Types

Common Ecto field types:

| Type              | Elixir Type   | Database   |
| ----------------- | ------------- | ---------- |
| `:string`         | String        | VARCHAR    |
| `:integer`        | Integer       | INTEGER    |
| `:float`          | Float         | FLOAT      |
| `:boolean`        | Boolean       | BOOLEAN    |
| `:map`            | Map           | JSON/JSONB |
| `:text`           | String        | TEXT       |
| `:naive_datetime` | NaiveDateTime | TIMESTAMP  |
| `:utc_datetime`   | DateTime      | TIMESTAMP  |

### Associations

Define relationships between schemas:

```elixir
defmodule Hello.User do
  schema "users" do
    field :name, :string
    has_many :posts, Hello.Post
  end
end

defmodule Hello.Post do
  schema "posts" do
    field :title, :string
    belongs_to :user, Hello.User
  end
end
```

## Changesets & Validations

Changesets define transformation pipelines for data, handling type-casting, validation, and parameter filtering. They enable safe data processing:

```elixir
defmodule Hello.Post do
  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title, :body, :published_at])
    |> validate_required([:title, :body])
    |> validate_length(:title, min: 1, max: 255)
    |> validate_length(:body, min: 5)
    |> validate_format(:title, ~r/^[a-zA-Z0-9 ]+$/)
  end
end
```

### Validation Functions

```elixir
validate_required(changeset, [:title, :body])
validate_length(changeset, :title, min: 1, max: 255)
validate_number(changeset, :price, greater_than: 0)
validate_inclusion(changeset, :status, ["active", "inactive"])
validate_format(changeset, :email, ~r/@/)
validate_confirmation(changeset, :password)
validate_change(changeset, :email, fn :email, email ->
  if Enum.member?(allowed_emails(), email) do
    []
  else
    [email: "not in allowed list"]
  end
end)
```

### Safe Parameter Filtering

The `cast/3` function filters external input, only accepting fields you explicitly list:

```elixir
# Only these fields from params are accepted and validated
changeset = Post.changeset(%Post{}, params)
|> cast(params, [:title, :body])

# User cannot set :admin field even if they send it
# cast/3 ignores it automatically
```

## Repository Pattern

The `Repo` module provides the database interface:

```elixir
defmodule Hello.Repo do
  use Ecto.Repo,
    otp_app: :hello,
    adapter: Ecto.Adapters.Postgres
end
```

Repositories manage connection pooling, query execution, and error translation.

## Querying

### Basic Queries

```elixir
# Get all posts
posts = Repo.all(Post)

# Get single post by ID
post = Repo.get(Post, 1)
post = Repo.get_by(Post, title: "Hello")

# Get or raise
post = Repo.get!(Post, 1)
```

### Filtering and Transforming

```elixir
import Ecto.Query

# Build query with conditions
query = Post
  |> where(published: true)
  |> where([p], p.title != "")
  |> order_by([p], desc: p.inserted_at)
  |> limit(10)

posts = Repo.all(query)

# Pagination
offset = (page - 1) * 20
query = Post |> offset(^offset) |> limit(20)
```

### Aggregation

```elixir
# Count posts
count = Repo.aggregate(Post, :count, :id)

# Get maximum value
max_id = Repo.aggregate(Post, :max, :id)

# Sum
total = Repo.aggregate(Post, :sum, :views)
```

## Insert, Update, Delete

### Insert

```elixir
changeset = Post.changeset(%Post{}, params)
case Repo.insert(changeset) do
  {:ok, post} ->
    # Success
    post
  {:error, changeset} ->
    # Handle validation errors
    changeset.errors
end
```

### Update

```elixir
post = Repo.get(Post, 1)
changeset = Post.changeset(post, updated_params)
case Repo.update(changeset) do
  {:ok, updated_post} -> updated_post
  {:error, changeset} -> changeset.errors
end
```

### Delete

```elixir
post = Repo.get(Post, 1)
Repo.delete(post)
```

## Best Practices

- **Always validate in changesets**: Let Ecto handle type-casting and validation, not controller code.
- **Use migrations for schema changes**: Never alter the database directly; create migrations that are version-controlled and reproducible.
- **Eager load associations**: Use `preload/2` to prevent N+1 query problems.
- **Name changesets clearly**: Use `create_changeset/2`, `update_changeset/2` for different flows if validation differs.
- **Transaction support**: Wrap multi-step operations in `Repo.transaction/1` to ensure atomicity.

---

[← Back to main](phoenix-1.8.8.md)  
**Version:** 1.8.8
