# Recipe: SQLite3 Upsert Patterns with Ecto

## Problem

SQLite3 doesn't support the `RETURNING` clause that PostgreSQL provides, making it impossible to use Ecto's `on_conflict` with `returning: true` for upserts. This is problematic when you need to implement "add or replace" behavior (like user reactions where each user can only have one reaction per message, but can change it).

## Solution

Use a delete+insert pattern instead of relying on `on_conflict` with `RETURNING`. This approach:

1. Deletes any existing record matching the unique constraint
2. Inserts the new record
3. Returns the newly created record

This works consistently across both SQLite3 (development) and PostgreSQL (production).

## Implementation

### Database Schema

First, ensure you have a unique index to enforce the constraint:

```elixir
# priv/repo/migrations/YYYYMMDDHHMMSS_create_reactions.exs
defmodule MyApp.Repo.Migrations.CreateReactions do
  use Ecto.Migration

  def change do
    create table(:reactions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :message_id, references(:messages, type: :binary_id, on_delete: :delete_all)
      add :user_id, :integer
      add :emoji, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:reactions, [:message_id, :user_id])
  end
end
```

### Context Function with Delete+Insert Pattern

```elixir
# lib/my_app/chat.ex
defmodule MyApp.Chat do
  import Ecto.Query
  alias MyApp.Chat.{Message, Reaction}
  alias MyApp.Repo

  @doc """
  Adds or replaces a reaction to a message.
  Uses delete+insert pattern since SQLite3 doesn't support RETURNING.
  """
  @spec add_reaction(String.t(), integer(), String.t()) ::
          {:ok, Reaction.t()} | {:error, Ecto.Changeset.t() | :message_not_found}
  def add_reaction(message_id, user_id, emoji) do
    case Repo.get(Message, message_id) do
      nil ->
        {:error, :message_not_found}

      _message ->
        # Step 1: Delete existing reaction (if any)
        delete_query =
          from(r in Reaction,
            where: r.message_id == ^message_id and r.user_id == ^user_id
          )

        Repo.delete_all(delete_query)

        # Step 2: Insert new reaction
        %Reaction{}
        |> Reaction.changeset(%{emoji: emoji, message_id: message_id, user_id: user_id})
        |> Repo.insert()
    end
  end
end
```

### Schema with Unique Constraint Validation

```elixir
# lib/my_app/chat/reaction.ex
defmodule MyApp.Chat.Reaction do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "reactions" do
    field(:emoji, :string)
    field(:user_id, :integer)
    belongs_to(:message, MyApp.Chat.Message)
    timestamps(type: :utc_datetime)
  end

  def changeset(reaction, attrs) do
    reaction
    |> cast(attrs, [:emoji, :message_id, :user_id])
    |> validate_required([:emoji, :message_id, :user_id])
    |> validate_inclusion(:user_id, [1, 2])
    |> validate_length(:emoji, min: 1, max: 10)
    |> foreign_key_constraint(:message_id)
    |> unique_constraint([:message_id, :user_id])
  end
end
```

## Considerations

### When to Use

- **Cross-database compatibility**: When you need the same code to work on both SQLite3 (dev) and PostgreSQL (prod)
- **Unique constraints**: When implementing "one record per combination" logic (e.g., one reaction per user per message)
- **Upsert semantics**: When you need "add or replace" behavior

### When NOT to Use

- **PostgreSQL-only**: If you're only using PostgreSQL, use `on_conflict: {:replace, [:field1, :field2]}, returning: true` for better performance
- **No unique constraint**: If you don't have a unique constraint, just use regular `Repo.insert/2`
- **High concurrency**: The delete+insert pattern is not atomic - use database transactions if concurrent upserts are possible

### Performance Considerations

- **Two queries**: This pattern executes two database queries (DELETE then INSERT) vs one with `on_conflict`
- **Transaction overhead**: Each operation is a separate transaction unless wrapped in `Repo.transaction`
- **Good enough**: For low-to-moderate traffic apps, the performance difference is negligible
- **Race conditions**: If two processes try to upsert the same record simultaneously, one will fail with unique constraint violation

### Alternative Approach (Transaction-wrapped)

For better atomicity, wrap in a transaction:

```elixir
def add_reaction(message_id, user_id, emoji) do
  Repo.transaction(fn ->
    case Repo.get(Message, message_id) do
      nil ->
        Repo.rollback(:message_not_found)

      _message ->
        delete_query =
          from(r in Reaction,
            where: r.message_id == ^message_id and r.user_id == ^user_id
          )

        Repo.delete_all(delete_query)

        case %Reaction{}
             |> Reaction.changeset(%{emoji: emoji, message_id: message_id, user_id: user_id})
             |> Repo.insert() do
          {:ok, reaction} -> reaction
          {:error, changeset} -> Repo.rollback(changeset)
        end
    end
  end)
end
```

## Example Usage

From the nalikutemwa chat app implementation:

```elixir
# User adds reaction
{:ok, reaction} = Chat.add_reaction(message_id, user_id, "👍")
# => Returns %Reaction{emoji: "👍", user_id: 1, message_id: "..."}

# User changes reaction (replaces previous)
{:ok, updated} = Chat.add_reaction(message_id, user_id, "❤️")
# => Returns %Reaction{emoji: "❤️", user_id: 1, message_id: "..."}

# User removes reaction
:ok = Chat.remove_reaction(message_id, user_id)
```

## Related Recipes

- Database sanitization for preview apps (database-sanitization-preview.md)
