# ash - Calculations & Expressions

## Calculations

Calculations are "complex values displayed as a top level value of a resource." They enable you to compute and surface derived data alongside your core resource attributes. Calculations don't require storing computed values—they're computed on-demand when loaded.

### Expression Calculations

Use Ash expressions for simpler operations:

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource

  attributes do
    uuid_primary_key :id
    attribute :first_name, :string
    attribute :last_name, :string
    attribute :age, :integer
  end

  calculations do
    # Concatenate strings
    calculate :full_name, :string, expr(first_name <> " " <> last_name)

    # Conditional logic
    calculate :is_adult, :boolean, expr(age >= 18)
  end
end

# Load and use
user =
  MyApp.Accounts.User
  |> Ash.Query.filter(id: user_id)
  |> Ash.Query.load(:full_name)
  |> Ash.read_one!()

IO.inspect(user.full_name)  # "John Doe"
```

### Module Calculations

Handle more complex logic by implementing `Ash.Resource.Calculation`:

```elixir
defmodule MyApp.Calculations.UserPostCount do
  use Ash.Resource.Calculation

  def init(opts) do
    {:ok, opts}
  end

  def load(_query, _opts, _context) do
    [:posts]  # Specify fields that need to be loaded
  end

  def calculate(records, _opts, _context) do
    Enum.map(records, fn record ->
      Enum.count(record.posts)
    end)
  end
end

# Use in resource
defmodule MyApp.Accounts.User do
  use Ash.Resource

  calculations do
    calculate :post_count, :integer, MyApp.Calculations.UserPostCount
  end
end
```

### Calculations with Arguments

Customize calculation behavior with arguments:

```elixir
defmodule MyApp.Calculations.UserGreeting do
  use Ash.Resource.Calculation

  def init(opts) do
    {:ok, opts}
  end

  def calculate(records, opts, _context) do
    prefix = opts[:prefix] || "Hello"

    Enum.map(records, fn record ->
      "#{prefix}, #{record.first_name}!"
    end)
  end
end

# Use with custom arguments
calculations do
  calculate :greeting, :string, MyApp.Calculations.UserGreeting do
    argument :prefix, :string, default: "Hi"
  end
end

# Load with custom values
user =
  MyApp.Accounts.User
  |> Ash.Query.load([greeting: %{prefix: "Greetings"}])
  |> Ash.read_one!()
```

### Loading Calculations

Load calculations with `Ash.Query.load/2` or `Ash.load/3`:

```elixir
# Single calculation
user = Ash.load!(user, :full_name)

# Multiple calculations
users = Ash.load!(users, [:full_name, :post_count])

# With custom arguments
user = Ash.load!(user, [greeting: %{prefix: "Welcome"}])

# Store with custom name
user =
  user
  |> Ash.Query.load([full_name: [as: :display_name]])
  # Access via record.calculations[:display_name]
```

## Expressions

Ash expressions are portable representations of Elixir code designed to work across different data layers—whether SQL databases or Elixir runtime.

### Creating Expressions

Use the `Ash.Expr.expr/1` macro:

```elixir
import Ash.Expr

# Simple field reference
expr(user.name)

# Arithmetic
expr(price * quantity)

# String concatenation
expr(first_name <> " " <> last_name)

# Comparison
expr(age >= 18)

# Boolean logic
expr(status == :active and age >= 21)
```

### SQL-like Semantics

Ash expressions follow SQL conventions, not pure Elixir:

```elixir
# nil "poisons" expressions like SQL NULL
expr(x + nil)  # Returns nil
expr(x and nil)  # Returns nil
expr(x or nil)  # Returns nil

# Atoms and strings are equivalent
expr(status == :active)  # Matches both atoms and strings
```

### Operators

#### Comparison Operators

```elixir
expr(age == 21)
expr(price != 100)
expr(count > 5)
expr(age >= 18)
expr(rating < 4)
expr(total <= 1000)
```

#### Boolean Operators

```elixir
# Preferred for SQL performance
expr(status == :active and age >= 21)
expr(role == :admin or role == :moderator)
expr(not is_archived)

# Alternative operators (less efficient in SQL)
expr(status == :active && age >= 21)
expr(role == :admin || role == :moderator)
```

#### String and Collection Operators

```elixir
expr(tags in [tag1, tag2, tag3])
expr(name <> " " <> surname)  # String concatenation
expr(string_downcase(name))
expr(string_split(tags, ","))
```

### Common Functions

#### String Functions

```elixir
expr(string_downcase(name))
expr(string_upcase(email))
expr(string_length(description))
expr(string_split(tags, ","))
```

#### Type Conversion

```elixir
expr(type(value, :string))
expr(type(value, :integer))
```

#### Aggregates

```elixir
expr(count(posts, true))  # Count all posts
expr(sum(orders.total, 0))  # Sum total from orders
expr(max(prices))
expr(min(prices))
```

#### Date/Time Functions

```elixir
expr(now())  # Current datetime
expr(ago(now(), 7, :day))  # 7 days ago
expr(datetime_add(created_at, 30, :day))  # Add 30 days
```

#### Conditional Functions

```elixir
expr(if(age >= 18, "Adult", "Minor"))

expr(cond do
  age >= 65 -> "Senior"
  age >= 18 -> "Adult"
  true -> "Minor"
end)
```

### Dynamic Value Injection

Safely parameterize expressions:

```elixir
import Ash.Expr

# Access action arguments
expr(user_id == ^arg(:user_id))

# Reference current user (actor)
expr(owner_id == ^actor(:id))

# Access context data
expr(organization_id == ^context(:org_id))

# Dynamic field references
expr(^ref(:status) == :active)
```

### Filtering with Relationships

Important distinction: filters reference single row combinations:

```elixir
# Find comments with points > 10 AND tag named "elixir"
# This describes one post-comment-tag combination
Post
|> Ash.Query.filter(
  expr(comments.points > 10 and comments.tag.name == "elixir")
)

# For proper many-to-many filtering, use exists/2
Post
|> Ash.Query.filter(
  expr(exists(comments, points > 10 and tag.name == "elixir"))
)
```

## Difference: Calculations vs Aggregates

Calculations serve a different purpose than aggregates:

- **Calculations** compute derived values from existing data (e.g., full name from first/last name)
- **Aggregates** perform statistical operations across related records (e.g., count comments on a post)

Use calculations for computed fields, aggregates for statistical summaries.

---

[← Back to main](ash-3.7.6.md)
**Version:** 3.7.6
