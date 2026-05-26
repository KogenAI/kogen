# ash_money

AshMoney is an extension for working with money types in Ash applications. It wraps the `ex_money` library to bring financial data handling capabilities with currency support to the Ash framework. This enables structured monetary operations, database-level aggregates, and type-safe money handling.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:ash_money, "~> 0.2.4"}
  ]
end
```

For PostgreSQL integration with aggregates and expressions, also add:

```elixir
{:ex_money_sql, "~> 1.0"}
```

### Basic Usage

Declare a money attribute in your Ash resource:

```elixir
attribute :balance, AshMoney.Types.Money
```

Or using Igniter (recommended):

```bash
mix igniter.install ash_money
```

## Core Concepts

### Money Type

`AshMoney.Types.Money` is a composite type that represents monetary values with currency. It wraps `ex_money` to provide:

- Type-safe money handling with currency codes
- Integration with Ash's runtime expressions and operators
- Database persistence with currency support
- Structured queries and filtering by currency

### Type Registration

Enable money operations in runtime expressions:

```elixir
config :ash, :known_types, [AshMoney.Types.Money]
```

Create a shorthand alias for convenience:

```elixir
config :ash, :custom_types, money: AshMoney.Types.Money
```

Then reference as `:money` instead of the full module name.

### Composite Type Pattern

Use in composite structures:

```elixir
composite_type(%{currency: "USD", amount: Decimal.new("100.50")}, AshMoney.Types.Money)
```

Or with custom alias:

```elixir
composite_type(%{currency: "USD", amount: Decimal.new("100.50")}, :money)
```

## Configuration

### Attribute Declaration

Basic declaration:

```elixir
attribute :balance, :money
```

With options:

```elixir
attribute :charge, :money do
  constraints: [
    storage_type: :money_with_currency,
    ex_money_opts: [
      no_fraction_if_integer: true,
      format: :short
    ]
  ]
end
```

### Configuration Options

**`storage_type`** — Controls database persistence format:

- `:money_with_currency` (default) — Stores amount and currency together
- `:map` — Stores as separate fields (only relevant when `ex_money_sql` is installed)

**`ex_money_opts`** — Passes options to `Money.new/3` from the `ex_money` library. Common options:

- `no_fraction_if_integer: true` — Omit decimal places for whole numbers
- `format: :short` — Use concise currency formatting

### PostgreSQL Setup

1. Add the extension to your repo:

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres
  use AshPostgres.Repo
end
```

2. Register in installed extensions:

```elixir
defmodule MyApp.Repo do
  use AshPostgres.Repo do
    def installed_extensions do
      ["uuid-ossp", AshMoney.AshPostgresExtension]
    end
  end
end
```

3. Generate and run migrations to enable aggregate functions and expression filtering.

### GraphQL Support

Define corresponding types in your GraphQL schema:

```elixir
object :charge do
  field :amount, :decimal
  field :currency, :string
end
```

## Best Practices

### Currency Handling

Always specify currency codes using ISO 4217 standards (USD, EUR, GBP, etc.). The `ex_money` library validates currency codes at runtime.

### Aggregates with Money

Use money in sum aggregates to calculate total amounts across resources:

```elixir
aggregate :total_balance, :sum, :balance
```

Filter by currency in queries:

```elixir
filter(query, currency: "USD")
```

### Type Safety

Leverage Ash's type system for compile-time safety. Always declare money attributes explicitly to catch currency/amount mismatches early.

### Database Optimization

When using PostgreSQL, leverage the `AshPostgresExtension` for:

- Native database aggregates on monetary values
- Efficient filtering by currency in expressions
- Type-safe comparisons in queries

Avoid casting Money values to maps unless necessary; keep them in their structured form for better performance.

### Configuration Best Practices

- Use Igniter for automated setup when available
- Configure `known_types` globally in config.exs for consistent behavior
- Create custom type aliases (`:money`) to reduce boilerplate
- Test money constraints with edge cases (zero amounts, fractional currencies)

---

**Version:** 0.2.4
**Source:** [hexdocs.pm/ash_money](https://hexdocs.pm/ash_money/)
**Generated:** 2025-10-28
