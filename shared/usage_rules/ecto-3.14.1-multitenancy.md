# ecto - Multi-Tenancy Patterns

Multi-tenancy architectures isolate data between different customers or organizations. Ecto supports several patterns; this guide covers the foreign-key approach, which is cost-effective and leverages database constraints for data integrity.

## Core Architecture

The foreign-key pattern stores an `org_id` (or `tenant_id`) on every resource record. Each organization's data is isolated by filtering on this field.

```elixir
defmodule MyApp.Organization do
  use Ecto.Schema
  schema "organizations" do
    field :name, :string
  end
end

defmodule MyApp.User do
  use Ecto.Schema
  schema "users" do
    field :name, :string
    field :org_id, :id
    belongs_to :organization, MyApp.Organization
  end
end

defmodule MyApp.Post do
  use Ecto.Schema
  schema "posts" do
    field :title, :string
    field :org_id, :id
    belongs_to :organization, MyApp.Organization
  end
end
```

## Process-Level Tenant Context

Store the current tenant's org_id in the process dictionary so it's accessible throughout request handling:

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.Postgres

  @impl true
  def prepare_query(_operation, query, opts) do
    cond do
      opts[:skip_org_id] -> {query, opts}
      is_nil(Process.get(:org_id)) -> {query, opts}
      true -> {apply_org_id(query, Process.get(:org_id)), opts}
    end
  end

  @impl true
  def default_options(opts) do
    Keyword.merge(opts, org_id: Process.get(:org_id))
  end

  defp apply_org_id(query, org_id) do
    import Ecto.Query
    where(query, org_id: ^org_id)
  end
end
```

Set the organization context in a plug or middleware:

```elixir
defmodule MyApp.TenantPlug do
  def init(opts), do: opts

  def call(conn, _opts) do
    org_id = get_org_from_session(conn)
    Process.put_dict(:org_id, org_id)
    conn
  end

  defp get_org_from_session(conn) do
    # Retrieve from session, subdomain, header, etc.
  end
end
```

## Automatic Query Scoping

The `prepare_query/3` callback intercepts all queries and applies org_id filtering automatically. Built-in exceptions prevent scoping migrations and preload operations:

```elixir
defp apply_org_id(query, org_id) do
  import Ecto.Query

  case query do
    # Skip scoping for raw SQL and special operations
    %Ecto.Query{from: %{source: {"schema_migrations", _}}} -> query

    # Apply org_id filter to normal queries
    %Ecto.Query{} -> where(query, org_id: ^org_id)

    # Handle other cases
    _ -> query
  end
end
```

Opt-out of scoping when necessary:

```elixir
# This query won't be scoped
MyApp.Repo.all(MyApp.User, skip_org_id: true)
```

## Composite Foreign Keys for Data Integrity

Enforce that related records belong to the same organization using composite foreign keys:

```elixir
create table(:posts) do
  add :title, :string
  add :org_id, :id, null: false
  add :author_id, references(:users, with: [org_id: :org_id], on_delete: :cascade)
  timestamps()
end

create table(:comments) do
  add :body, :text
  add :org_id, :id, null: false
  add :post_id, references(:posts, with: [org_id: :org_id], on_delete: :cascade)
  add :author_id, references(:users, with: [org_id: :org_id], on_delete: :cascade)
  timestamps()
end
```

This ensures that comments cannot be associated with posts from a different organization—the database enforces consistency.

## Querying Across Organizations

Sometimes you need to query data from all organizations (e.g., system reports):

```elixir
# Skip automatic scoping
all_posts = MyApp.Repo.all(MyApp.Post, skip_org_id: true)

# Or use raw SQL
import Ecto.Query
from p in MyApp.Post,
  where: p.org_id in ^[org_1_id, org_2_id],
  select: p
```

## Testing with Multiple Tenants

In tests, set up different organizations in separate test cases:

```elixir
setup do
  org1 = MyApp.Repo.insert!(%MyApp.Organization{name: "Org 1"})
  org2 = MyApp.Repo.insert!(%MyApp.Organization{name: "Org 2"})

  {:ok, org1: org1, org2: org2}
end

test "users see only their org's posts", %{org1: org1, org2: org2} do
  user1 = MyApp.Repo.insert!(%MyApp.User{name: "User 1", org_id: org1.id})
  post1 = MyApp.Repo.insert!(%MyApp.Post{title: "Post 1", org_id: org1.id})
  post2 = MyApp.Repo.insert!(%MyApp.Post{title: "Post 2", org_id: org2.id})

  # Set context to org1
  Process.put_dict(:org_id, org1.id)

  # Query returns only org1's posts
  posts = MyApp.Repo.all(MyApp.Post)
  assert length(posts) == 1
  assert Enum.all?(posts, &(&1.org_id == org1.id))
end
```

## Advantages

This pattern provides:

- **Cost efficiency**: Single shared database reduces infrastructure costs
- **Data isolation**: Composite keys prevent cross-tenant data leakage
- **Scalability**: Easy to add new tenants without schema changes
- **Simplicity**: Leverages database constraints rather than complex application logic
- **Performance**: Direct database enforcement beats application-level checks

---

[← Back to main](ecto-3.14.1.md)
**Version:** 3.14.1
