# ex_money_sql

Money SQL is an Elixir library that enables storing and retrieving monetary data in databases while preserving precision and currency integrity. It implements custom Ecto data types for serializing `%Money{}` structs—which contain ISO 4217 currency codes paired with decimal amounts—without losing precision.

## Quick Start

### Installation

Add to your `mix.exs`:

```elixir
{:ex_money_sql, "~> 1.0"}
```

Requires Elixir 1.11 or later.

### Basic Schema Setup

```elixir
defmodule MyApp.Account do
  use Ecto.Schema
  import Ecto.Changeset

  schema "accounts" do
    field :balance, Money.Ecto.Composite.Type  # PostgreSQL
    # OR
    field :balance, Money.Ecto.Map.Type        # MySQL/SQLite
  end

  def changeset(account, attrs) do
    account
    |> cast(attrs, [:balance])
    |> validate_required([:balance])
  end
end
```

## Core Concepts

### Money Struct

Money values are represented as `%Money{currency: "USD", amount: Decimal.new("100.00")}`. The library automatically converts between user input and Money structs through Ecto casting.

### Database Type Selection

**PostgreSQL**: Use `Money.Ecto.Composite.Type` - stores as a composite database type called `:money_with_currency`. The serialized money amount is stored as a decimal number, making this the preferred option for PostgreSQL with native database-level arithmetic support.

**MySQL and Other Databases**: Use `Money.Ecto.Map.Type` - stores as JSON maps. Precision is maintained by serializing the amount as a string within the JSON structure to avoid rounding errors.

### Critical Configuration for Embedded Schemas

When using money fields in embedded schemas, you **must** use `Money.Ecto.Map.Type`, not `Money.Ecto.Composite.Type`. As of version 1.9.2, incorrect configuration raises a Jason encoding protocol error:

```elixir
# ❌ WRONG in embedded schemas
embeds_one :metadata, Metadata do
  field :amount, Money.Ecto.Composite.Type
end

# ✅ CORRECT in embedded schemas
embeds_one :metadata, Metadata do
  field :amount, Money.Ecto.Map.Type
end
```

## Configuration

### Casting and Type Conversion

The `cast/1` and `cast/2` functions accept multiple input formats:

```elixir
# Maps with currency and amount keys
{:ok, money} = Money.Ecto.Composite.Type.cast(%{"currency" => "USD", "amount" => "100.50"})

# String parsing (locale-aware)
{:ok, money} = Money.Ecto.Composite.Type.cast("$100.50")

# Atoms, integers, or Decimal values
{:ok, money} = Money.Ecto.Composite.Type.cast(%{currency: :USD, amount: Decimal.new("100.50")})

# Handles nil values
{:ok, nil} = Money.Ecto.Composite.Type.cast(nil)
```

### Locale-Aware Parsing

String parsing interprets input according to the current locale's number formatting rules. **Critical**: Decimal separators (`,` vs `.`) and grouping conventions vary by region. Misaligned locale settings can cause unexpected results—"1.00" might be interpreted as "100" with incorrect locale configuration.

### Embedded Schema Type Callbacks

`Money.Ecto.Map.Type` implements these callbacks for embedded schemas:

- **`init/1`** - Initializes type parameters
- **`cast/2`** - Transforms user input into Money type
- **`type/1`** - Returns the underlying schema type (`:map`)
- **`load/3`** - Converts database maps into Money structures
- **`dump/3`** - Serializes Money objects to database-compatible maps
- **`equal?/2`** - Compares Money values for equality
- **`embed_as/1`** - Defines embedding behavior for nested schemas

## Best Practices

### Precision Handling

Always use Decimal for amount values to maintain precision. The library serializes amounts as strings in JSON storage to prevent floating-point rounding errors.

### Migration Considerations for PostgreSQL

For PostgreSQL, ensure your migrations create the composite type:

```elixir
def up do
  execute("CREATE TYPE money_with_currency AS (amount decimal, currency char(3))")
end

def down do
  execute("DROP TYPE money_with_currency")
end
```

### Database Arithmetic

PostgreSQL's composite type enables native database-level arithmetic and aggregations:

```elixir
# Query with sum, min, max operations
query =
  from a in Account,
  select: {sum(a.balance), min(a.balance), max(a.balance)}

Repo.one(query)
```

### Validation

Always validate monetary fields in changesets:

```elixir
def changeset(account, attrs) do
  account
  |> cast(attrs, [:balance])
  |> validate_required([:balance])
  |> validate_money_field(:balance)
end

defp validate_money_field(changeset, field) do
  case get_change(changeset, field) do
    %Money{amount: amount} when amount > 0 -> changeset
    _ -> add_error(changeset, field, "must be a positive monetary amount")
  end
end
```

### Currency Handling

Explicitly manage currency codes in your business logic. The library preserves currency information but doesn't enforce conversion rules—handle multi-currency operations in application code.

---

**Version:** 1.11.0
**Source:** [hexdocs.pm/ex_money_sql](https://hexdocs.pm/ex_money_sql/)
**Generated:** 2025-10-28
