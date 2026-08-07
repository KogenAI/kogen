# ex_machina

ExMachina is an Elixir library for generating test data through factory functions. It provides a structured, composable approach to creating fixtures with support for overrides, sequences, and lazy evaluation.

## Quick Start

### Installation

Add to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:ex_machina, "~> 2.8", only: :test}
  ]
end
```

### Basic Factory Definition

Factories are callback modules defining factory functions. Create a factory module in `test/support/factories.ex`:

```elixir
defmodule MyApp.Factory do
  use ExMachina

  def user_factory do
    %{name: "John Doe", email: "john@example.com", admin: false}
  end

  def article_factory do
    %{title: "Test Article", body: "Content", author_id: build(:user).id}
  end
end
```

### Using Factories in Tests

```elixir
defmodule MyApp.UserTest do
  use ExUnit.Case
  import MyApp.Factory

  test "user creation" do
    user = build(:user)
    assert user.name == "John Doe"
  end

  test "override attributes" do
    admin = build(:user, admin: true)
    assert admin.admin == true
  end

  test "build multiple instances" do
    users = build_list(3, :user)
    assert length(users) == 3
  end
end
```

## Core Concepts

### Factory Functions

Factories follow naming conventions: `[factory_name]_factory/0` or `[factory_name]_factory/1`.

**Simple factories (no attributes):**

```elixir
def user_factory do
  %{name: "John", email: "john@example.com"}
end
```

**Attribute-aware factories (with parameter):**
When defining factories with an attributes parameter, ExMachina no longer automatically merges attributes—you must handle merging manually:

```elixir
def user_factory(attrs) do
  %{name: "John", email: "john@example.com"}
  |> Map.merge(attrs)
end
```

### Build Operations

- **`build(:factory_name)`** — Creates a single instance
- **`build(:factory_name, attrs)`** — Creates instance with attribute overrides
- **`build_list(n, :factory_name)`** — Generates n instances
- **`build_list(n, :factory_name, attrs)`** — Generates n instances with overrides
- **`build_pair(:factory_name)`** — Shorthand for creating exactly two instances

### Sequences

Generate unique values automatically:

```elixir
def user_factory do
  %{
    name: "John",
    username: sequence("username"),
    email: sequence(:email, &"user-#{&1}@example.com")
  }
end
```

Sequence features:

- `sequence("base")` — Produces "base0", "base1", "base2", etc.
- `sequence(:name, formatter_fn)` — Apply custom formatting
- `sequence(:name, formatter_fn, start_at: 100)` — Start numbering at 100

### Lazy Attributes

Use lambdas for attributes that should be evaluated fresh on each build:

```elixir
def article_factory do
  %{
    title: "Test Article",
    # Shared author instance—only built once
    author: build(:user),
    # Fresh author per article—built each time
    reviewer: fn -> build(:user) end
  }
end
```

This matters when using sequences or requiring independent instances per factory call.

### Helper Functions

- **`merge_attributes/2`** — Combines generated data with attribute overrides
- **`evaluate_lazy_attributes/1`** — Processes lambda-wrapped attributes, enabling fresh value generation

## Configuration

### Module Setup

Define factories in a dedicated module using `use ExMachina`:

```elixir
defmodule MyApp.Factory do
  use ExMachina

  # Factory definitions...
end
```

### Import in Tests

Add to your test case:

```elixir
defmodule MyApp.SomeTest do
  use ExUnit.Case
  import MyApp.Factory

  # Tests...
end
```

Or configure globally in `test/test_helper.exs`:

```elixir
{:ok, _} = Application.ensure_all_started(:ex_machina)
```

## Best Practices

### Organize Factory Definitions

Group related factories and use composition:

```elixir
def user_factory do
  %{name: "John", email: sequence(:email, &"user#{&1}@example.com")}
end

def admin_factory(attrs) do
  user = build(:user)
  Map.merge(user, attrs)
  |> Map.put(:admin, true)
end
```

### Use Lazy Evaluation for Relationships

When building nested structures, prefer lazy evaluation to create independent instances:

```elixir
def article_factory do
  %{
    title: "Article",
    author: fn -> build(:user) end,  # Fresh user per article
    tags: fn -> build_list(2, :tag) end
  }
end
```

### Keep Factories Simple

Avoid complex logic in factories. If setup requires significant computation, consider test-specific helpers or database setup.

### Use Attribute Overrides

Leverage `build/2` overrides instead of creating multiple factory variants:

```elixir
# Instead of separate published_article_factory, draft_article_factory:
build(:article, published: true)
build(:article, published: false)
```

### Sequence Naming

Use semantic names for sequences that indicate their purpose:

```elixir
sequence(:email, &"test-#{&1}@example.com")
sequence("username_")  # Results in "username_0", "username_1"
```

### Test Performance

Factories generate data in memory. For performance-sensitive tests, consider:

- Building only necessary attributes
- Using `build/2` instead of inserting to database when possible
- Creating reusable test fixtures for expensive operations

---

**Version:** 2.8.2
**Source:** [hexdocs.pm/ex_machina](https://hexdocs.pm/ex_machina/2.8.2)
**Generated:** 2026-08-07
