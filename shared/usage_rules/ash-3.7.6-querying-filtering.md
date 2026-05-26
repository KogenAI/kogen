# ash - Querying & Filtering

## Query Basics

Ash provides a portable query API that works consistently across all data layers. Queries encapsulate how you retrieve and filter data from resources.

### Reading Records

#### Read One Record

```elixir
# Get first matching record
{:ok, user} =
  MyApp.Accounts.User
  |> Ash.Query.filter(email: "alice@example.com")
  |> Ash.read_one()

# Bang version - raises on error
user = Ash.read_one!(user_query)
```

#### Read Multiple Records

```elixir
{:ok, users} =
  MyApp.Accounts.User
  |> Ash.read()

# With filters
{:ok, active_users} =
  MyApp.Accounts.User
  |> Ash.Query.filter(status: :active)
  |> Ash.read()
```

### Basic Filtering

#### Exact Match

```elixir
MyApp.Accounts.User
|> Ash.Query.filter(status: :active, role: :admin)
|> Ash.read!()
```

#### Comparison Operators

```elixir
import Ash.Expr

# Greater than
MyApp.Orders.Order
|> Ash.Query.filter(expr(total > 100))
|> Ash.read!()

# Less than or equal
MyApp.Events.Event
|> Ash.Query.filter(expr(attendee_count <= 50))
|> Ash.read!()

# Not equal
MyApp.Posts.Post
|> Ash.Query.filter(expr(status != :draft))
|> Ash.read!()
```

#### String Matching

```elixir
import Ash.Expr

# Contains substring
MyApp.Accounts.User
|> Ash.Query.filter(expr(string_downcase(name) <> "*smith*"))
|> Ash.read!()

# Regex pattern matching
MyApp.Accounts.User
|> Ash.Query.filter(expr(match(email, ".*@example\\.com$")))
|> Ash.read!()
```

#### Range Checks

```elixir
import Ash.Expr

# Between values
MyApp.Products.Product
|> Ash.Query.filter(expr(price >= 10 and price <= 100))
|> Ash.read!()

# In a list
MyApp.Posts.Post
|> Ash.Query.filter(expr(status in [:published, :scheduled]))
|> Ash.read!()
```

### Combining Filters

```elixir
import Ash.Expr

query = MyApp.Orders.Order
  |> Ash.Query.filter(expr(status == :completed))
  |> Ash.Query.filter(expr(total > 50))

# OR logic using expr
MyApp.Posts.Post
|> Ash.Query.filter(expr(author_id == ^arg(:user_id) or public == true))
|> Ash.read!()
```

## Sorting

### Single Sort

```elixir
MyApp.Posts.Post
|> Ash.Query.sort(inserted_at: :desc)
|> Ash.read!()

# Ascending (default)
MyApp.Accounts.User
|> Ash.Query.sort(name: :asc)
|> Ash.read!()
```

### Multiple Sorts

```elixir
MyApp.Orders.Order
|> Ash.Query.sort([
  {status: :desc},
  {created_at: :desc}
])
|> Ash.read!()

# Alternative syntax
MyApp.Orders.Order
|> Ash.Query.sort(status: :desc, created_at: :desc)
|> Ash.read!()
```

### Sort by Relationship

```elixir
MyApp.Posts.Post
|> Ash.Query.load(:author)
|> Ash.Query.sort(author: [name: :asc])
|> Ash.read!()
```

## Pagination

### Offset Pagination

```elixir
page_size = 20
page = 2
offset = (page - 1) * page_size

MyApp.Posts.Post
|> Ash.Query.limit(page_size)
|> Ash.Query.offset(offset)
|> Ash.read!()
```

### Keyset Pagination

More efficient for large datasets:

```elixir
# First page
posts =
  MyApp.Posts.Post
  |> Ash.Query.sort(inserted_at: :desc, id: :asc)
  |> Ash.Query.limit(20)
  |> Ash.read!()

# Get last post's keyset for next page
last_post = List.last(posts)
next_keyset = {last_post.inserted_at, last_post.id}

# Get next page
next_posts =
  MyApp.Posts.Post
  |> Ash.Query.sort(inserted_at: :desc, id: :asc)
  |> Ash.Query.after(next_keyset)
  |> Ash.Query.limit(20)
  |> Ash.read!()
```

### Limit

```elixir
# Return at most 50 records
MyApp.Posts.Post
|> Ash.Query.limit(50)
|> Ash.read!()
```

## Loading Related Data

### Load Relationships

```elixir
user =
  MyApp.Accounts.User
  |> Ash.Query.load(:posts)
  |> Ash.read_one!()

# Multiple relationships
user =
  MyApp.Accounts.User
  |> Ash.Query.load([:posts, :comments, :profile])
  |> Ash.read_one!()
```

### Nested Loads

```elixir
user =
  MyApp.Accounts.User
  |> Ash.Query.load(
    posts: [
      :author,
      comments: [:author]
    ]
  )
  |> Ash.read_one!()

# Access nested data
Enum.each(user.posts, fn post ->
  Enum.each(post.comments, fn comment ->
    IO.inspect(comment.author.name)
  end)
end)
```

### Load with Filters

```elixir
user =
  MyApp.Accounts.User
  |> Ash.Query.filter(id: user_id)
  |> Ash.Query.load(
    posts:
      MyApp.Posts.Post
      |> Ash.Query.filter(status: :published)
      |> Ash.Query.sort(created_at: :desc)
      |> Ash.Query.limit(10)
  )
  |> Ash.read_one!()
```

### Load Calculations

```elixir
user =
  MyApp.Accounts.User
  |> Ash.Query.load(:full_name)  # Load calculation
  |> Ash.read_one!()

IO.inspect(user.full_name)
```

## Distinct & Select

### Select Specific Fields

```elixir
MyApp.Posts.Post
|> Ash.Query.select([:id, :title, :created_at])
|> Ash.read!()

# User.posts will only contain these fields
```

### Distinct Results

```elixir
# Remove duplicates
MyApp.Tags.Tag
|> Ash.Query.distinct(:name)
|> Ash.read!()
```

## Complex Queries

### Combining All Features

```elixir
import Ash.Expr

posts =
  MyApp.Posts.Post
  |> Ash.Query.filter(expr(
    status == :published and
    created_at > ago(now(), 30, :day) and
    author.status == :active
  ))
  |> Ash.Query.load(:author)
  |> Ash.Query.load(:comments)
  |> Ash.Query.sort(created_at: :desc)
  |> Ash.Query.limit(20)
  |> Ash.read!()
```

### Using the read Action

```elixir
# Define custom read action in resource
actions do
  read :published_posts do
    filter expr(status == :published)
    sort created_at: :desc
  end
end

# Call the action
MyApp.Posts.Post
|> Ash.read!(action: :published_posts)
```

## Query Performance

### Specify Needed Data

Load only relationships and fields you need:

```elixir
# ✅ Load only what you need
users =
  MyApp.Accounts.User
  |> Ash.Query.load(:name)
  |> Ash.Query.select([:id, :name])
  |> Ash.read!()

# ❌ Avoid loading unnecessary relationships
users =
  MyApp.Accounts.User
  |> Ash.Query.load([:posts, :comments, :followers, :following])
  |> Ash.read!()
```

### Use Aggregates for Counts

Instead of loading all related records just to count them, use aggregates:

```elixir
# ❌ Inefficient - loads all posts
users =
  MyApp.Accounts.User
  |> Ash.Query.load(:posts)
  |> Ash.read!()

Enum.map(users, fn user -> Enum.count(user.posts) end)

# ✅ Efficient - counts in database
MyApp.Accounts.User
|> Ash.Query.load(:post_count)  # Via aggregate or calculation
|> Ash.read!()
```

---

[← Back to main](ash-3.7.6.md)
**Version:** 3.7.6
