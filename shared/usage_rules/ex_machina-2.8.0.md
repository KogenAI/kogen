# ex_machina

ExMachina is an Elixir library for generating test data through factory functions. It provides callbacks and helper functions to build single records, multiple records, or pairs of records with customizable attributes. Factories reduce boilerplate in tests by defining reusable data templates.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:ex_machina, "~> 2.8.0", only: :test}
  ]
end
```

### Basic Factory Definition

Create `test/support/factory.ex`:

```elixir
defmodule MyApp.Factory do
  use ExMachina

  def user_factory do
    %MyApp.User{
      name: "John Doe",
      email: sequence(:email, &"user#{&1}@example.com"),
      active: true
    }
  end

  def post_factory do
    %MyApp.Post{
      title: "My Post",
      body: "Content here",
      user_id: build(:user).id
    }
  end
end
```

Register in test helper:

```elixir
# test/test_helper.exs
ExUnit.start()
{:ok, _} = Application.ensure_all_started(:myapp)
```

### Basic Usage in Tests

```elixir
use MyApp.Factory

test "user creation" do
  user = build(:user)
  assert user.email == "user0@example.com"

  admin = build(:user, active: false)
  assert admin.active == false
end
```

## Core Concepts

### Build Functions

**`build(factory_name, attributes \\ [])`** – Returns unsaved record (struct/map):

```elixir
user = build(:user)
user_with_attrs = build(:user, name: "Alice", email: "alice@test.com")
```

**`build_list(count, factory_name, attributes \\ [])`** – Returns list of records:

```elixir
users = build_list(5, :user)
admins = build_list(3, :user, active: true)
```

**`build_pair(factory_name, attributes \\ [])`** – Returns tuple of exactly 2 records:

```elixir
{user1, user2} = build_pair(:user)
```

### Sequences

Sequences generate unique values automatically, typically for email/username fields:

```elixir
def user_factory do
  %User{
    email: sequence(:email, &"user#{&1}@example.com")
  }
end
```

The `&1` is the counter (0, 1, 2, ...). Access sequence value directly:

```elixir
def account_factory do
  %Account{
    slug: sequence("account_slug")  # generates "account_slug0", "account_slug1"
  }
end
```

**Custom Start Point:**

```elixir
sequence(:id, &(&1 + 1000))  # starts at 1000
sequence(:email, &"test#{&1}@example.com", start_at: 100)
```

### Factory with Callback (factory/1)

Use `[name]_factory/1` when you need custom logic or computed fields:

```elixir
def user_factory(attrs) do
  user = %User{
    name: "Default User",
    email: sequence(:email, &"user#{&1}@example.com"),
    password_hash: hash_password("password")
  }
  merge_attributes(user, attrs)
end

def post_factory(attrs) do
  post = %Post{
    title: "Default Title",
    user_id: build(:user).id
  }

  post
  |> merge_attributes(attrs)
  |> evaluate_lazy_attributes()
end
```

### Lazy Attributes

Use functions to generate fresh data per record (critical for `build_list`):

```elixir
def comment_factory do
  %Comment{
    body: fn -> "Comment #{System.unique_integer()}" end,
    author_id: fn -> build(:user).id end
  }
end

# Without lazy attributes - all 3 records share same ID!
def comment_factory do
  %Comment{
    body: "Comment #{System.unique_integer()}",  # WRONG
    author_id: build(:user).id                     # WRONG
  }
end
```

**Evaluate Lazy Attributes:**

```elixir
def comment_factory(attrs) do
  %Comment{
    body: fn -> "Comment #{System.unique_integer()}" end,
    author_id: fn -> build(:user).id end
  }
  |> merge_attributes(attrs)
  |> evaluate_lazy_attributes()
end

# Each call generates fresh data
comment1 = build(:comment)
comment2 = build(:comment)  # Different IDs and bodies
```

## Configuration

### Module-Level Settings

```elixir
defmodule MyApp.Factory do
  use ExMachina

  # Factory convention: [name]_factory/0 or [name]_factory/1
  # Default behavior requires these function names
end
```

### Sequence Management

Reset sequences between test modules:

```elixir
setup do
  ExMachina.Sequence.reset()
  :ok
end
```

Persist across tests if needed (some teams prefer global sequence):

```elixir
# Don't reset - sequences continue across all tests
```

### Associations

Define relationships between factories:

```elixir
def post_factory do
  %Post{
    title: "Test Post",
    user: build(:user),  # Embeds full user struct
    user_id: build(:user).id  # Just the ID
  }
end

def comment_factory do
  %Comment{
    post_id: build(:post).id,
    author_id: build(:user).id
  }
end
```

Use in tests:

```elixir
post = build(:post)  # User automatically built
comment = build(:comment, post_id: post.id)
```

## Best Practices

### Use Lazy Attributes for Lists

When building lists, wrap dynamic values in functions:

```elixir
# ✅ CORRECT - Each record gets unique ID
def user_factory do
  %User{
    email: sequence(:email, &"user#{&1}@example.com"),
    account_id: fn -> build(:account).id end
  }
end

users = build_list(5, :user)  # Each has different account_id

# ❌ WRONG - All records share same ID
def user_factory do
  %User{
    email: sequence(:email, &"user#{&1}@example.com"),
    account_id: build(:account).id  # Same ID in all 5 records
  }
end
```

### Keep Factories Minimal

Define only required attributes; override in tests:

```elixir
def user_factory do
  %User{
    name: "User",
    email: sequence(:email, &"user#{&1}@example.com")
  }
end

# Override in test
admin = build(:user, role: :admin, verified: true)
```

### Reset Sequences for Determinism

If tests depend on exact sequence values:

```elixir
setup do
  ExMachina.Sequence.reset()
  :ok
end

test "sequence starts at 0" do
  user = build(:user)
  assert user.email == "user0@example.com"
end
```

### Separate Factory Modules

For large projects, organize by domain:

```elixir
# test/support/factories/user_factory.ex
defmodule MyApp.UserFactory do
  use ExMachina
  def user_factory, do: %User{...}
end

# test/support/factories/post_factory.ex
defmodule MyApp.PostFactory do
  use ExMachina
  def post_factory, do: %Post{...}
end

# test/support/factory.ex - Combine all
defmodule MyApp.Factory do
  use ExMachina
  alias MyApp.{UserFactory, PostFactory}
  # Re-export or compose
end
```

### Use Traits for Variants

Create factory functions for common variations:

```elixir
def admin_user_factory(attrs) do
  build(:user, attrs)
  |> Map.put(:role, :admin)
  |> merge_attributes(attrs)
end

def verified_user_factory(attrs) do
  build(:user, verified_at: DateTime.utc_now())
  |> merge_attributes(attrs)
end

# In tests
admin = build(:admin_user)
verified = build(:verified_user, name: "Alice")
```

---

**Version:** 2.8.0
**Source:** https://hexdocs.pm/ex_machina/
**Generated:** 2025-10-28
