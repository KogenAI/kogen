# ecto - Querying and Query Composition

Ecto provides a powerful query builder that enables composing complex database queries in pure Elixir code. Queries are built incrementally using pipe operations and remain database-agnostic until executed.

## Basic Query Syntax

Queries use the `Ecto.Query` module and can be written in keyword or pipe syntax:

```elixir
import Ecto.Query

# Keyword syntax
query = from u in MyApp.User, where: u.age > 18, select: u.name

# Pipe syntax
query = from(u in MyApp.User)
  |> where([u], u.age > 18)
  |> select([u], u.name)

# Execute with repository
MyApp.Repo.all(query)
```

Both syntaxes are composable and produce identical queries.

## Core Query Operations

```elixir
# Filtering
from(u in MyApp.User, where: u.email == "john@example.com")

# Ordering
from(u in MyApp.User, order_by: [desc: u.inserted_at])

# Limiting and offsetting
from(u in MyApp.User, limit: 10, offset: 20)

# Selecting specific fields
from(u in MyApp.User, select: %{id: u.id, name: u.name})

# Distinct results
from(u in MyApp.User, distinct: true)

# Grouping
from(u in MyApp.User, group_by: u.email)
```

## Joining Tables

Join associations using the `join` macro:

```elixir
# Inner join
from p in MyApp.Post,
  join: u in assoc(p, :author),
  where: u.name == "John",
  select: p

# Left outer join
from p in MyApp.Post,
  left_join: c in assoc(p, :comments),
  select: {p, c}

# Named bindings for complex joins
from p in MyApp.Post,
  as: :post,
  join: c in assoc(p, :comments),
  as: :comment,
  where: p.id == c.post_id
```

## Aggregates and Subqueries

Aggregates compute values like sums, averages, and counts:

```elixir
# Count
from(u in MyApp.User, select: count(u.id))

# Average
from(p in MyApp.Post, select: avg(p.views))

# Sum
from(o in MyApp.Order, select: sum(o.total))

# Using Repo.aggregate for complex aggregates
MyApp.Repo.aggregate(MyApp.Post, :count, :id)
```

Subqueries enable multi-step queries. Important: applying `limit` to an aggregate doesn't work because aggregates return one row. Instead, subquery first:

```elixir
# Get the 10 most recent posts, then count
subquery = from(p in MyApp.Post, order_by: [desc: p.inserted_at], limit: 10)
from(p in subquery(subquery), select: count(p.id))

# Find each book's most recent lender
subquery = from l in MyApp.Lending,
  group_by: l.book_id,
  select: %{book_id: l.book_id, max_id: max(l.id)}

from l in MyApp.Lending,
  join: s in subquery(subquery),
  on: s.max_id == l.id,
  select: {l.book_id, l.user_name}
```

## Dynamic Query Building

Use `dynamic/2` for conditional query construction:

```elixir
def filter_users(query, filters) do
  Enum.reduce(filters, query, fn
    {:age_min, min}, q -> where(q, [u], u.age >= ^min)
    {:age_max, max}, q -> where(q, [u], u.age <= ^max)
    {:name, name}, q -> where(q, [u], ilike(u.name, ^"%#{name}%"))
    _, q -> q
  end)
end

# Use in a query
from(u in MyApp.User) |> filter_users(%{age_min: 18, name: "John"})
```

For more complex scenarios with optional joins or fields, use the `dynamic/2` macro:

```elixir
def search_query(query, params) do
  dynamic = Enum.reduce(params, true, fn
    {:email, email}, d -> dynamic([u], ^d and u.email == ^email)
    {:verified, true}, d -> dynamic([u], ^d and u.verified == true)
    _, d -> d
  end)

  from(u in query, where: ^dynamic)
end
```

## Preloading Associated Data

Load associated records efficiently:

```elixir
# Simple preload
from(p in MyApp.Post, preload: :comments)

# Nested preload
from(p in MyApp.Post, preload: [comments: :author])

# Conditional preload
query = from(p in MyApp.Post)
posts = MyApp.Repo.preload(query, comments: :author)

# Custom preload query
query = from(c in MyApp.Comment, order_by: [desc: c.inserted_at], limit: 5)
MyApp.Repo.preload(posts, comments: query)
```

## Fragment Queries and Raw SQL

When Ecto's query builder is insufficient, use fragments for raw SQL:

```elixir
from u in MyApp.User,
  where: fragment("LOWER(?) = ?", u.email, ^String.downcase(email))

# Complex raw SQL
from p in MyApp.Post,
  select: fragment("DISTINCT ON (?) ?", p.author_id, p)
```

## Query Composition Patterns

Build reusable query functions:

```elixir
defmodule MyApp.UserQueries do
  import Ecto.Query

  def active(query) do
    where(query, [u], u.active == true)
  end

  def verified(query) do
    where(query, [u], u.verified == true)
  end

  def recent(query, days \\ 7) do
    where(query, [u], u.inserted_at > ago(^days, "day"))
  end
end

# Usage
from(u in MyApp.User)
|> MyApp.UserQueries.active()
|> MyApp.UserQueries.verified()
|> MyApp.UserQueries.recent(14)
|> MyApp.Repo.all()
```

---

[← Back to main](ecto-3.14.1.md)
**Version:** 3.14.1
