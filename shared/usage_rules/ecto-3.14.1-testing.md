# ecto - Testing Strategies

Ecto enables comprehensive testing through transactions, factories, and patterns that ensure data isolation and repeatability across test suites.

## Database Transaction Isolation

Ecto automatically wraps each test in a database transaction that rolls back after the test completes, preventing test data from persisting and ensuring isolation:

```elixir
defmodule MyApp.UserTest do
  use ExUnit.Case

  setup do
    # Transaction begins before test
    :ok
  end

  test "creates a user" do
    user = MyApp.Repo.insert!(%MyApp.User{name: "John"})
    assert user.id
    # Transaction rolls back after test
  end
end
```

For async tests that run in parallel, each test receives its own transaction:

```elixir
defmodule MyApp.PostTest do
  use ExUnit.Case, async: true

  test "post has title" do
    post = MyApp.Repo.insert!(%MyApp.Post{title: "Hello"})
    assert post.title == "Hello"
  end

  test "another post" do
    post = MyApp.Repo.insert!(%MyApp.Post{title: "World"})
    assert post.title == "World"
    # No collision with first test despite both creating posts
  end
end
```

## Test Factories

Build reusable test data generators without external dependencies by leveraging Ecto's capabilities:

```elixir
defmodule MyApp.Factory do
  alias MyApp.Repo

  def build(factory_name, attrs \\ %{})

  def build(:user, attrs) do
    Enum.into(attrs, %MyApp.User{
      name: "John Doe",
      email: "john#{System.unique_integer()}@example.com"
    })
  end

  def build(:post, attrs) do
    Enum.into(attrs, %MyApp.Post{
      title: "Sample Post",
      body: "Lorem ipsum"
    })
  end

  def build(:comment, attrs) do
    Enum.into(attrs, %MyApp.Comment{
      body: "Great post!",
      user: build(:user)
    })
  end

  def build(:post_with_comments, attrs) do
    post = build(:post, attrs)
    comments = [
      build(:comment, post: post),
      build(:comment, post: post)
    ]
    Map.put(post, :comments, comments)
  end

  def insert!(factory_name, attrs \\ %{}) do
    factory_name
    |> build(attrs)
    |> Repo.insert!()
  end

  def insert(factory_name, attrs \\ %{}) do
    factory_name
    |> build(attrs)
    |> Repo.insert()
  end
end
```

Include the factory in test compilation by updating `mix.exs`:

```elixir
def project do
  [
    app: :my_app,
    version: "0.1.0",
    elixir: "~> 1.14",
    elixirc_paths: elixirc_paths(Mix.env()),
    # ... other config
  ]
end

defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(_), do: ["lib"]
```

## Using Factories in Tests

Build structs without persistence:

```elixir
test "validates user email" do
  user = MyApp.Factory.build(:user, email: "invalid")
  assert {:error, changeset} = MyApp.Repo.insert(MyApp.User.changeset(user, %{}))
  assert "email" in Keyword.keys(changeset.errors)
end
```

Insert and persist:

```elixir
test "fetches a user by id" do
  user = MyApp.Factory.insert!(:user, name: "Alice")
  fetched = MyApp.Repo.get(MyApp.User, user.id)
  assert fetched.name == "Alice"
end
```

Create complex related data:

```elixir
test "post with comments" do
  post = MyApp.Factory.insert!(:post_with_comments)
  post = MyApp.Repo.preload(post, :comments)
  assert length(post.comments) == 2
end
```

## Factory Customization

Define factory variations for common scenarios:

```elixir
defmodule MyApp.Factory do
  def build(:admin_user, attrs) do
    Enum.into(attrs, %MyApp.User{
      name: "Admin",
      email: "admin#{System.unique_integer()}@example.com",
      role: "admin"
    })
  end

  def build(:inactive_user, attrs) do
    Enum.into(attrs, %MyApp.User{
      name: "Inactive",
      email: "inactive#{System.unique_integer()}@example.com",
      active: false
    })
  end
end
```

Override specific attributes:

```elixir
test "admin user has admin role" do
  user = MyApp.Factory.insert!(:admin_user, name: "Alice")
  assert user.role == "admin"
  assert user.name == "Alice"  # Custom override applied
end
```

## Seeding Test Data

For integration tests requiring consistent baseline data:

```elixir
setup do
  users = [
    MyApp.Factory.insert!(:user, name: "Alice"),
    MyApp.Factory.insert!(:user, name: "Bob")
  ]

  posts = [
    MyApp.Factory.insert!(:post, title: "First", user: Enum.at(users, 0)),
    MyApp.Factory.insert!(:post, title: "Second", user: Enum.at(users, 1))
  ]

  {:ok, users: users, posts: posts}
end

test "lists all posts", %{posts: posts} do
  all_posts = MyApp.Repo.all(MyApp.Post)
  assert length(all_posts) == length(posts)
end
```

## Cleaning Up in Tests

While transaction rollback handles most cleanup, occasionally you need explicit cleanup:

```elixir
test "with manual cleanup" do
  file = MyApp.Factory.insert!(:file)

  # Perform test...

  # Manual cleanup
  File.rm(file.path)
  MyApp.Repo.delete(file)
end
```

## Testing Changesets Without Database

Test validation logic without database operations:

```elixir
test "changeset validates required fields" do
  changeset = MyApp.User.changeset(%MyApp.User{}, %{})

  refute changeset.valid?
  assert "name" in Keyword.keys(changeset.errors)
  assert "email" in Keyword.keys(changeset.errors)
end

test "changeset accepts valid data" do
  attrs = %{name: "John", email: "john@example.com"}
  changeset = MyApp.User.changeset(%MyApp.User{}, attrs)

  assert changeset.valid?
  assert changeset.changes.name == "John"
end
```

## Advantages of Ecto Factory Pattern

This implementation offers:

- **No dependencies**: Builds on top of Ecto itself
- **Extensibility**: Easily add custom factory logic
- **Simplicity**: Clear relationship between factory name and generated data
- **Performance**: Minimal overhead compared to external factory libraries
- **Type safety**: Leverage Ecto's built-in validation and type checking

---

[← Back to main](ecto-3.14.1.md)
**Version:** 3.14.1
