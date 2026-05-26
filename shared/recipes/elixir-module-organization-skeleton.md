# Elixir Module Organization Skeleton

**Problem**: Inconsistent ordering of `use`, `import`, `alias`, attributes, types, and functions triggers Credo warnings and makes modules hard to scan.
**When**: Creating a new module or reviewing an existing module's structure during a code review.
**See also**: none

## Solution

Follow this fixed order, with a blank line between each group and no blank lines within a group:

```elixir
defmodule MyApp.Accounts.User do
  @moduledoc "..."        # or @moduledoc false for schemas

  use Phoenix.LiveView     # 1. use statements

  import Ecto.Changeset    # 2. imports (blank line before)

  require Logger           # 3. require (blank line before)

  alias MyApp.Accounts     # 4. aliases, alphabetical (blank line before)
  alias MyApp.Repo

  @primary_key {:id, :binary_id, autogenerate: true}  # 5. module attributes (blank line before)

  @type t :: %__MODULE__{}  # 6. type definitions (blank line before)

  schema "users" do         # 7. schema (blank line before)
    field :email, :string
    timestamps()
  end

  def public_fn, do: ...    # 8. functions (blank line before)
  defp private_fn, do: ...
end
```

**CRITICAL**: One blank line between each numbered group. No blank lines within a group.

Alias order is alphabetical within the group. `use` → `import` → `require` → `alias` is the canonical sort.

## Gotchas

- `@moduledoc false` is conventional for schemas — it suppresses "missing doc" warnings without requiring a meaningful description.
- Module attributes (`@primary_key`, `@timestamps_opts`, etc.) come before type definitions, which come before schema.
- Functions with `@impl` follow the same placement rule — they belong in section 8 regardless of whether they are public or "implementation" functions.
