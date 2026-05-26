# ash_double_entry

AshDoubleEntry is an Elixir extension for the Ash framework that provides foundational building blocks for implementing customizable double-entry accounting systems. It abstracts the complexity of double-entry bookkeeping while allowing developers to extend functionality for domain-specific requirements.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:ash_double_entry, "~> 1.0.15"}
  ]
end
```

Run `mix deps.get`.

### Basic Setup

1. Create an Ash domain module for accounting
2. Define Account resources using the Account DSL
3. Define Transfer resources for transactions using the Transfer DSL
4. Configure Balance tracking for account snapshots

## Core Concepts

### Accounts

The `AshDoubleEntry.Account` DSL defines accounting accounts within the double-entry system.

**Key Features:**

- Store account types (asset, liability, equity, revenue, expense)
- Maintain account balances through transfers
- Support hierarchical account structures
- Track account metadata and classifications

### Transfers

The `AshDoubleEntry.Transfer` DSL represents financial transactions that move value between accounts.

**Key Features:**

- Define source and destination accounts for each transfer
- Automatically maintain double-entry integrity (debit/credit balance)
- Support transfer metadata and context
- Atomic transaction processing

### Balances

The `AshDoubleEntry.Balance` DSL manages account balance snapshots.

**Key Features:**

- Calculate running balances per account
- Snapshot balances at specific timestamps
- Efficient balance queries for reporting
- Support historical balance tracking

## Configuration

### Defining Accounts

```elixir
defmodule MyApp.Accounts.Account do
  use Ash.Resource, domain: MyApp.Accounts

  ash_double_entry do
    account do
      code :string
      name :string
      type :atom  # asset, liability, equity, revenue, expense
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :code, :string, allow_nil?: false
    attribute :name, :string, allow_nil?: false
    attribute :type, :atom, allow_nil?: false
  end
end
```

### Defining Transfers

```elixir
defmodule MyApp.Transactions.Transfer do
  use Ash.Resource, domain: MyApp.Transactions

  ash_double_entry do
    transfer do
      source_account_id :uuid
      destination_account_id :uuid
      amount :decimal
    end
  end
end
```

### Tracking Balances

```elixir
defmodule MyApp.Accounts.Balance do
  use Ash.Resource, domain: MyApp.Accounts

  ash_double_entry do
    balance do
      account_id :uuid
      at_date :date
      balance :decimal
    end
  end
end
```

## Best Practices

### Transaction Integrity

- Use atomic transactions to ensure both debit and credit sides are recorded together
- Validate that transfers balance (total debits = total credits)
- Prevent partial transaction recording through proper error handling

### Account Structure

- Organize accounts hierarchically by type (Assets → Current Assets → Cash)
- Use consistent account coding systems (Chart of Accounts)
- Document account purposes and allowed transaction types

### Balance Management

- Calculate balances at consistent intervals for performance
- Archive old balance snapshots for historical reporting
- Use indexed queries on account_id and timestamp for efficient lookups

### Error Handling

- Validate account types support the transfer direction
- Enforce non-negative balances for restricted account types
- Log all transactions for audit trails

### Performance Optimization

- Index transfer queries by account_id and timestamp
- Use balance snapshots instead of recalculating from transfers
- Batch balance calculations during off-peak hours
- Implement pagination for large account listings

---

**Version:** 1.0.15
**Source:** [hexdocs.pm/ash_double_entry](https://hexdocs.pm/ash_double_entry/)
**Generated:** 2025-10-28
