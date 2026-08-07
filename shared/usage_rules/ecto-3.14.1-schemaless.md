# ecto - Schemaless Operations

Ecto enables powerful database operations without requiring schema definitions. This flexibility is invaluable for dynamic queries, reporting, and scenarios where defining schemas would be redundant.

## Query Without Schemas

Write queries directly against tables without schema modules:

```elixir
import Ecto.Query

# Select specific fields from a table
from "users", select: [:id, :name, :email]

# Select all fields
from "posts"

# Filter and order
from "orders",
  where: [status: "pending"],
  order_by: [desc: :created_at],
  select: [:id, :total, :created_at]
```

This approach eliminates redundant field declarations while maintaining type safety through Ecto's type system.

## Type Safety Without Schemas

Use the `type/2` function to preserve type-casting guarantees:

```elixir
import Ecto.Query

# Define types for schemaless data
query = from "users",
  where: type(field(:name), :string) == ^name,
  where: type(field(:age), :integer) > ^18
```

Ecto casts and validates data according to the specified types during query interpolation.

## Update Operations

Schemaless updates support four update commands:

```elixir
import Ecto.Query

# Set values
from("users", where: [id: 1])
|> update(set: [name: "John", email: "john@example.com"])
|> MyApp.Repo.update_all()

# Increment numeric columns atomically
from("posts", where: [id: post_id])
|> update(inc: [views: 1])
|> MyApp.Repo.update_all()

# Push values to array columns
from("users", where: [id: 1])
|> update(push: [roles: "admin"])
|> MyApp.Repo.update_all()

# Pull (remove) values from array columns
from("users", where: [id: 1])
|> update(pull: [roles: "guest"])
|> MyApp.Repo.update_all()
```

Return affected row count:

```elixir
{count, nil} = from("users", where: [active: false])
  |> update(set: [active: true])
  |> MyApp.Repo.update_all()

IO.puts("Updated #{count} users")
```

## Bulk Insert Operations

Insert multiple records without schemas:

```elixir
import Ecto.Query

rows = [
  %{name: "Alice", email: "alice@example.com"},
  %{name: "Bob", email: "bob@example.com"},
  %{name: "Charlie", email: "charlie@example.com"}
]

MyApp.Repo.insert_all("users", rows)
```

Include conflict handling:

```elixir
MyApp.Repo.insert_all(
  "tags",
  [%{name: "elixir"}, %{name: "erlang"}],
  on_conflict: :nothing,
  conflict_target: :name
)
```

## Bulk Delete Operations

Delete multiple records:

```elixir
from("comments", where: [post_id: ^post_id])
|> MyApp.Repo.delete_all()
```

Return count of deleted rows:

```elixir
{deleted_count, nil} = from("posts", where: [author_id: ^author_id])
  |> MyApp.Repo.delete_all()

IO.puts("Deleted #{deleted_count} posts")
```

## Reporting Use Cases

Schemaless queries excel in reporting scenarios where the domain model doesn't align with report structure:

```elixir
import Ecto.Query

# Monthly revenue report
from "orders",
  where: fragment("DATE_TRUNC('month', created_at) = ?", ^month),
  group_by: :customer_id,
  select: %{
    customer_id: :customer_id,
    total_revenue: sum(:amount),
    order_count: count(:id)
  }
```

It's often counterproductive to define schemas for temporary reporting structures—schemaless queries provide direct access to data aggregation without schema overhead.

## Dynamic Field Selection

Select different fields based on runtime conditions:

```elixir
fields = if admin? do
  [:id, :name, :email, :password_hash, :role, :created_at]
else
  [:id, :name, :email]
end

from("users", select: ^fields)
|> MyApp.Repo.all()
```

## Joining Without Schema Associations

Join tables by explicit foreign keys without schema association definitions:

```elixir
from p in "posts",
  join: u in "users", on: p.author_id == u.id,
  where: u.active == true,
  select: {p, u.name}
```

This enables querying relationships that don't warrant permanent schema definitions.

## When to Use Schemaless vs Schemas

**Use schemaless queries for:**

- Reports and analytics where data shape is temporary
- Dynamic queries with runtime-determined fields
- Simple CRUD on tables that don't need validation
- Bulk operations on large datasets
- Querying relationships not represented in your schema

**Use schemas for:**

- Regular application entities with validation
- Data that needs changeset transformations
- Complex relationships and associations
- Reusable validation rules across the application
- Nested or embedded data structures

---

[← Back to main](ecto-3.14.1.md)
**Version:** 3.14.1
