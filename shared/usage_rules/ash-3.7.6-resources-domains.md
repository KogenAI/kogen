# ash - Resources & Domains

## Resources

Resources are the foundational building blocks of Ash applications. Each resource is defined as a module that declares its attributes, actions, relationships, validations, and persistence strategy. Resources represent entities in your domain model and encapsulate all logic related to interacting with that entity.

### Basic Resource Structure

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource,
    domain: MyApp.Accounts,
    data_layer: :ets

  # Attributes define the data structure
  attributes do
    uuid_primary_key :id
    attribute :name, :string
    attribute :email, :string
  end

  # Actions define what operations are available
  actions do
    read :list_all
    create :create do
      accept [:name, :email]
    end
    update :update do
      accept [:name]
    end
  end
end
```

### Resource Options

- **`domain`** - Required parent domain module that groups related resources
- **`data_layer`** - Specifies persistence backend (`:ets`, `:sqlite`, `:postgres`, etc.)
- **`table`** - Database table name for SQL-based data layers (defaults to resource name in snake_case)
- **`plural_name`** - Human-readable plural form for resources (auto-derived from name)

## Domains

Domains are organizational units that group related resources together and provide centralized configuration. Think of domains as the Ash equivalent to Phoenix Contexts—they organize related functionality and provide a unified interface.

### Domain Organization

```elixir
defmodule MyApp.Accounts do
  use Ash.Domain

  resources do
    resource MyApp.Accounts.User
    resource MyApp.Accounts.Profile
    resource MyApp.Accounts.Role
  end

  # Optional: Centralized authorization
  authorization do
    authorize :by_default
  end
end
```

### Domain Functions

Domains allow you to define a clean code interface by exposing specific actions:

```elixir
defmodule MyApp.Accounts do
  use Ash.Domain

  resources do
    resource MyApp.Accounts.User
  end

  define :create_user, action: :create, args: [:email, :name]
  define :list_users, action: :list_all
  define :get_user, action: :read_one, args: [:id]
end

# Usage in code
{:ok, user} = MyApp.Accounts.create_user(email, name)
```

### Domain-Level Configuration

Configure behaviors affecting all contained resources:

```elixir
defmodule MyApp.Accounts do
  use Ash.Domain

  resources do
    resource MyApp.Accounts.User
  end

  # Set default transaction behavior
  config :transaction_decorator, true

  # Set default timeout
  config :execution, %{timeout: 30_000}
end
```

## Key Patterns

### Separation of Concerns

Each resource owns its attributes, validations, and relationships. Keep business logic localized to the resource:

```elixir
defmodule MyApp.Projects.Project do
  use Ash.Resource, domain: MyApp.Projects, data_layer: :postgres

  attributes do
    uuid_primary_key :id
    attribute :name, :string
    attribute :status, :atom, one_of: [:planning, :active, :complete]
  end

  relationships do
    belongs_to :owner, MyApp.Accounts.User
    has_many :tasks, MyApp.Projects.Task
  end

  validations do
    validate present(:name)
  end
end
```

### Resource Composition

Use relationships to connect resources and compose business operations across domains:

```elixir
# Query user with projects and associated tasks
MyApp.Accounts.User
|> Ash.Query.filter(id: user_id)
|> Ash.Query.load(projects: [:tasks])
|> Ash.read_one!()
```

### Domain Delegation

Define domain functions that abstract action details and provide a clean API:

```elixir
defmodule MyApp.Accounts do
  use Ash.Domain

  resources do
    resource MyApp.Accounts.User
  end

  def register_user(email, password) do
    MyApp.Accounts.User
    |> Ash.Changeset.for_create(:register, %{email: email, password: password})
    |> Ash.create()
  end
end
```

---

[← Back to main](ash-3.7.6.md)
**Version:** 3.7.6
