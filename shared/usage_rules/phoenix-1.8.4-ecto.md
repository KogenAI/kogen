# phoenix - Ecto & Database Integration

## What is Ecto

Ecto is Elixir's data validation and persistence library integrated with Phoenix for database operations. It supports PostgreSQL, MySQL, MSSQL, ETS, and SQLite3 databases. Ecto provides type safety, SQL injection protection, compile-time optimization, and seamless error translation.

## Core Concepts

**Schemas** define how Elixir data types map to and from database tables:

```elixir
defmodule Hello.Users.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :name, :string
    field :email, :string
    field :age, :integer
    field :admin, :boolean, default: false
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

**Changesets** represent a pipeline of transformations data undergoes before use. They track changes, validation errors, and provide context about modifications:

```elixir
iex> User.changeset(%User{}, %{name: "Alice", email: "alice@example.com"})
#Ecto.Changeset<
  action: nil,
  changes: %{name: "Alice", email: "alice@example.com"},
  errors: [],
  data: #User<>,
  valid?: true
>
```

**Repository (Repo)** is the interface to your database, handling persistence, querying, connection pooling, and error translation:

```elixir
defmodule Hello.Repo do
  use Ecto.Repo,
    otp_app: :hello,
    adapter: Ecto.Adapters.Postgres
end
```

## Schema Generation

Generate schemas with migrations using `phx.gen.schema`:

```bash
mix phx.gen.schema Users.User users name:string email:string age:integer
```

This creates:

- `lib/hello/users/user.ex` — Schema module
- `priv/repo/migrations/20240425123456_create_users.exs` — Migration file

Run migrations:

```bash
mix ecto.create     # Create database
mix ecto.migrate    # Apply pending migrations
```

## Validation Patterns

**Required fields:**

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:name, :email])
  |> validate_required([:name, :email])
end
```

**Length validation:**

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:name, :email, :password])
  |> validate_required([:name, :email, :password])
  |> validate_length(:password, min: 8)
  |> validate_length(:name, max: 100)
end
```

**Format validation with regex:**

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:email])
  |> validate_format(:email, ~r/.+@.+\..+/)
end
```

**Uniqueness constraints:**

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:email])
  |> unique_constraint(:email)
end
```

**Custom validations:**

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:start_date, :end_date])
  |> validate_date_range()
end

defp validate_date_range(changeset) do
  start_date = get_change(changeset, :start_date)
  end_date = get_change(changeset, :end_date)

  if start_date && end_date && Date.compare(start_date, end_date) == :gt do
    add_error(changeset, :end_date, "must be after start date")
  else
    changeset
  end
end
```

## Data Persistence

**Insert (create):**

```elixir
changeset = User.changeset(%User{}, %{name: "Alice", email: "alice@example.com"})
case Repo.insert(changeset) do
  {:ok, user} -> IO.puts("User created: #{user.id}")
  {:error, changeset} -> IO.inspect(changeset.errors)
end

# Insert all (bulk)
Repo.insert_all(User, [
  %{name: "Bob", email: "bob@example.com"},
  %{name: "Charlie", email: "charlie@example.com"}
])
```

**Query (read):**

```elixir
# Get all users
users = Repo.all(User)

# Get one user by ID (raises if not found)
user = Repo.get!(User, 1)

# Get one user (nil if not found)
user = Repo.get(User, 1)

# Get one with condition
user = Repo.get_by(User, email: "alice@example.com")
```

**Update (modify):**

```elixir
user = Repo.get!(User, 1)
changeset = User.changeset(user, %{name: "Alice Updated"})
Repo.update(changeset)

# Update all matching
Repo.update_all(User, set: [admin: true])
```

**Delete (remove):**

```elixir
user = Repo.get!(User, 1)
Repo.delete(user)

# Delete all matching
Repo.delete_all(User)
```

## Query DSL

Ecto's query language provides SQL injection protection and compile-time optimization:

```elixir
import Ecto.Query

# Select all
Repo.all(User)

# Filter with where
query = from(u in User, where: u.admin == true)
Repo.all(query)

# Select specific fields
query = from(u in User, select: {u.id, u.name})
Repo.all(query)

# Ordering
query = from(u in User, order_by: u.name)
Repo.all(query)

# Count
query = from(u in User, select: count(u.id))
Repo.one(query)

# Complex conditions
query = from(u in User,
  where: u.admin == true and u.age > 18,
  order_by: u.name,
  limit: 10
)
Repo.all(query)

# Joins
query = from(u in User,
  join: p in Post, on: u.id == p.user_id,
  where: p.published == true,
  select: {u.name, p.title}
)
Repo.all(query)
```

## Associations

Define relationships between schemas:

```elixir
defmodule Hello.Users.User do
  schema "users" do
    field :name, :string
    has_many :posts, Hello.Posts.Post
  end
end

defmodule Hello.Posts.Post do
  schema "posts" do
    field :title, :string
    field :body, :string
    belongs_to :user, Hello.Users.User
  end
end
```

Load associations:

```elixir
# Lazy load
user = Repo.get!(User, 1)
posts = Repo.all(assoc(user, :posts))

# Eager load
user = Repo.get!(User, 1) |> Repo.preload(:posts)
```

## Migrations

Create migration files:

```bash
mix ecto.gen.migration add_admin_to_users
```

Migration structure:

```elixir
defmodule Hello.Repo.Migrations.AddAdminToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :admin, :boolean, default: false
    end
  end
end
```

Common migration operations:

```elixir
create table(:users) do
  add :name, :string
  add :email, :string, null: false
  add :age, :integer
  timestamps()
end

alter table(:users) do
  add :admin, :boolean, default: false
  remove :age
  modify :email, :string, null: true
end

drop table(:users)
create index(:users, [:email], unique: true)
```

Manage migrations:

```bash
mix ecto.migrate        # Apply pending migrations
mix ecto.rollback       # Revert last migration
mix ecto.rollback --step 3  # Revert 3 migrations
```

---

[← Back to main](phoenix-1.8.4.md)
**Version:** 1.8.4
