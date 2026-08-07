# ecto - Constraints and Data Integrity

Ecto provides mechanisms for handling database constraints and upsert operations, ensuring data integrity when race conditions or concurrent operations might occur.

## The Constraint Problem

When multiple concurrent operations attempt to create the same resource (e.g., two users submitting the same tag simultaneously), both may pass validation before either writes to the database, causing one insertion to fail with a unique constraint violation.

For example, in a many-to-many relationship between posts and tags:

```elixir
defmodule MyApp.Post do
  use Ecto.Schema
  import Ecto.Changeset

  schema "posts" do
    field :title, :string
    many_to_many :tags, MyApp.Tag, join_through: "posts_tags"
  end

  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title])
    |> cast_assoc(:tags)  # ❌ Problematic with race conditions
  end
end
```

## Using put_assoc Instead of cast_assoc

`cast_assoc/3` expects external parameters as maps with primary keys, making it unsuitable for handling data like comma-separated tag strings. Use `put_assoc/4` instead to explicitly control associations:

```elixir
def changeset(post, attrs) do
  post
  |> cast(attrs, [:title])
  |> put_assoc(:tags, attrs["tags"])  # Pass pre-fetched tag structs
end
```

## Constraint Checking in Changesets

Add constraint annotations to changesets so Ecto can handle database constraint failures gracefully:

```elixir
def changeset(tag, attrs) do
  tag
  |> cast(attrs, [:name])
  |> validate_required([:name])
  |> unique_constraint(:name)  # Declares constraint expectation
end
```

When insertion fails due to a constraint violation, handle it:

```elixir
case MyApp.Repo.insert(changeset) do
  {:ok, tag} -> {:ok, tag}
  {:error, changeset} ->
    # Retrieve the existing record
    existing = MyApp.Repo.get_by(MyApp.Tag, name: tag.name)
    {:ok, existing}
end
```

## Upsert Operations

Rather than checking-then-inserting, use Ecto's `:on_conflict` option for atomic upsert behavior:

```elixir
MyApp.Repo.insert(
  changeset,
  on_conflict: :nothing  # Do nothing if conflict occurs
)
```

For updating existing records on conflict, specify the conflict target and update values:

```elixir
MyApp.Repo.insert(
  changeset,
  on_conflict: [set: [updated_at: NaiveDateTime.utc_now()]],
  conflict_target: :email
)
```

## Bulk Upserts for Multiple Records

For creating multiple records with potential conflicts (e.g., associating many tags to a post), use `insert_all` with `:on_conflict`:

```elixir
# Convert tag names to tag structs
tag_data = Enum.map(tag_names, &%{name: &1})

# Insert all, ignoring conflicts
MyApp.Repo.insert_all(MyApp.Tag, tag_data, on_conflict: :nothing)

# Fetch all tag records in one query
tags = MyApp.Repo.all(from t in MyApp.Tag, where: t.name in ^tag_names)

# Associate with post
post |> MyApp.Post.changeset(%{}) |> Ecto.Changeset.put_assoc(:tags, tags) |> MyApp.Repo.update()
```

This optimizes from potentially 10+ database operations (one per tag) to just 2 queries: one bulk insert and one fetch.

## Composite Constraints

For multi-tenancy or complex relationships, use composite foreign keys to enforce consistency:

```elixir
defmodule MyApp.Organization do
  use Ecto.Schema
  schema "organizations" do
    field :name, :string
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

defmodule MyApp.Comment do
  use Ecto.Schema
  schema "comments" do
    field :body, :string
    field :post_id, :id
    field :org_id, :id
    # Composite key ensures comment's org_id matches post's org_id
    belongs_to :post, MyApp.Post, foreign_key: :post_id
  end
end
```

In migrations, define composite foreign keys:

```elixir
create table(:comments) do
  add :body, :text
  add :post_id, references(:posts, on_delete: :delete_all)
  add :org_id, references(:organizations,
    with: [post_id: :post_id],  # Ensures consistency
    on_delete: :delete_all
  )
end
```

## Constraint Types

Ecto supports various constraint types:

```elixir
def changeset(record, attrs) do
  record
  |> cast(attrs, [:field])
  |> unique_constraint(:field)                    # Unique index
  |> unique_constraint([:field1, :field2])       # Composite unique
  |> foreign_key_constraint(:parent_id)          # Foreign key
  |> exclusion_constraint(:email)                # Exclusion constraint
  |> check_constraint(:age, name: :age_check)   # Check constraint
end
```

## Idempotency

When using upserts without transactions, be aware that associated records may persist even if the main operation fails. This is acceptable if operations are idempotent—re-running them produces the same result.

---

[← Back to main](ecto-3.14.1.md)
**Version:** 3.14.1
