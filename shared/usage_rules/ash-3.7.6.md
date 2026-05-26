# ash

Ash is a comprehensive Elixir framework designed for building maintainable, well-structured data layer systems. It provides declarative resource definitions that encapsulate business logic, data validation, persistence, and authorization concerns. Resources act as the foundational building blocks—each defining attributes, actions, relationships, validations, and custom behavior. Ash abstracts away repetitive patterns through an expressive DSL while remaining flexible enough to accommodate complex domain requirements through custom implementations.

The framework emphasizes intentional design by requiring explicit action definitions rather than auto-generating generic CRUD operations. This approach enables rich, semantically meaningful interfaces that clearly communicate what operations are available. Domains organize related resources and provide centralized configuration for cross-cutting concerns like authorization policies and execution settings. Through data layers, Ash supports multiple persistence backends (ETS, SQLite, PostgreSQL) while maintaining a unified query and interaction API across all implementations.

## Quick Start

### Installation

Add Ash to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:ash, "~> 3.7"}
  ]
end
```

### Minimal Example

Define a domain and resource:

```elixir
defmodule MyApp.Accounts do
  use Ash.Domain
  resources do
    resource MyApp.Accounts.User
  end
end

defmodule MyApp.Accounts.User do
  use Ash.Resource, domain: MyApp.Accounts, data_layer: :ets

  attributes do
    uuid_primary_key :id
    attribute :name, :string
    attribute :email, :string, allow_nil?: false
  end

  actions do
    defaults [:create, :read, :update, :destroy]
  end
end
```

### Basic Operations

```elixir
# Create
{:ok, user} = MyApp.Accounts.User |> Ash.Changeset.for_create(:create, %{name: "Alice", email: "alice@example.com"}) |> Ash.create()

# Read
user = MyApp.Accounts.User |> Ash.read_one!()

# Update
{:ok, updated} = user |> Ash.Changeset.for_update(:update, %{name: "Alicia"}) |> Ash.update()

# Delete
:ok = user |> Ash.Changeset.for_destroy(:destroy) |> Ash.destroy()
```

## Documentation Sections

- [Resources & Domains](ash-3.7.6-resources-domains.md)
- [Attributes & Types](ash-3.7.6-attributes-types.md)
- [Actions: CRUD Operations](ash-3.7.6-actions.md)
- [Validations & Changes](ash-3.7.6-validations-changes.md)
- [Relationships Between Resources](ash-3.7.6-relationships.md)
- [Calculations & Expressions](ash-3.7.6-calculations-expressions.md)
- [Querying & Filtering](ash-3.7.6-querying-filtering.md)
- [Notifications & Side Effects](ash-3.7.6-notifications.md)

---

**Version:** 3.7.6
**Source:** [hexdocs.pm/ash](https://hexdocs.pm/ash/)
**Generated:** 2025-10-28
