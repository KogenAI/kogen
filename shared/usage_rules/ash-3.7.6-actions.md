# ash - Actions: CRUD Operations

## Actions Overview

Actions are the primary way to interact with resources. They encapsulate business logic and provide structured interfaces for data operations. Rather than auto-generating generic CRUD, Ash requires explicit action definitions—promoting intentional design and clear communication of what operations are available.

### Five Core Action Types

1. **Read** - Retrieve and query data
2. **Create** - Add new records
3. **Update** - Modify existing records
4. **Destroy** - Delete records
5. **Generic** - Custom business logic operations

## Defining Actions

### Basic Action Definition

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource, domain: MyApp.Accounts

  actions do
    # Simple read action
    read :list_all

    # Create action with input constraints
    create :create do
      accept [:name, :email]
      validate present(:email)
    end

    # Update action with specific fields
    update :update do
      accept [:name]
      require_atomic? false
    end

    # Destroy action
    destroy :destroy
  end
end
```

### Input Management with Accept

The `accept` directive controls which attributes an action receives as input:

```elixir
create :register do
  # Only these fields are accepted from user input
  accept [:email, :password]

  # Other attributes (like id, created_at) are ignored or generated
end

update :update_profile do
  # Only allow updating name and bio
  accept [:name, :bio]
end
```

### Default Accept

Use `default_accept` to set a fallback for all create/update actions:

```elixir
defmodule MyApp.Post do
  use Ash.Resource

  attributes do
    uuid_primary_key :id
    attribute :title, :string
    attribute :content, :string
    attribute :published, :boolean
  end

  actions do
    # Set default for all create/update actions
    default_accept [:title, :content]

    create :create
    update :update
    update :publish do
      accept [:published]  # Override default for this action
    end
  end
end
```

## Transaction Behavior

### Auto-Transactional Actions

Create, update, and destroy actions run within database transactions by default. This ensures atomicity—either all changes succeed or all fail together.

### Read/Generic Actions

Read and generic actions require explicit opt-in:

```elixir
read :count_all do
  transaction? true
end

generic :process_data do
  transaction? true
end
```

## Primary Actions

Mark actions as primary to enable framework automation and relationship management:

```elixir
defmodule MyApp.Projects.Project do
  use Ash.Resource

  actions do
    read :list_all do
      primary? true
    end

    create :create do
      primary? true
      accept [:name, :description]
    end

    update :update do
      primary? true
    end

    destroy :destroy do
      primary? true
    end
  end
end
```

Primary actions are used when:

- No explicit action is specified
- Managing relationships automatically
- Framework automation applies

## Action Execution

### Create and Update

```elixir
# Via changeset
{:ok, user} =
  MyApp.Accounts.User
  |> Ash.Changeset.for_create(:create, %{name: "Alice", email: "alice@example.com"})
  |> Ash.create()

# Update
{:ok, updated} =
  user
  |> Ash.Changeset.for_update(:update, %{name: "Alicia"})
  |> Ash.update()
```

### Read Operations

```elixir
# Read one record
{:ok, user} = Ash.read_one(
  Ash.Query.filter(MyApp.Accounts.User, email: "alice@example.com")
)

# Read all records
{:ok, users} = Ash.read(MyApp.Accounts.User)
```

### Destroy

```elixir
:ok = user |> Ash.Changeset.for_destroy(:destroy) |> Ash.destroy()
```

## Advanced Patterns

### Custom Business Logic Actions

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource

  actions do
    create :register do
      accept [:email, :password]
      validate present(:password)
      change hash_password()
    end

    generic :send_welcome_email do
      # Custom action for side effects
      argument :email, :string, allow_nil?: false
    end
  end
end
```

### Conditional Input

```elixir
defmodule MyApp.Orders.Order do
  use Ash.Resource

  actions do
    update :approve do
      accept [:approved_by]
      validate required_for_status(:approved)
      change calculate_total()
    end
  end
end
```

### Argument-Driven Actions

```elixir
generic :export do
  argument :format, :atom, one_of: [:csv, :json], default: :csv
  argument :filters, :map
end
```

## Best Practices

### Semantic Action Names

Prefer intention-revealing names over generic CRUD:

```elixir
# ✅ Good: Clear intent
create :register
create :import_from_csv
update :activate
update :approve
destroy :archive

# ❌ Avoid: Generic names
create :create
update :update
destroy :destroy
```

### Single Responsibility

Each action should represent one clear operation:

```elixir
# ✅ Separate actions for different purposes
create :register
create :create_admin

# ❌ Avoid: One action doing too much
create :create do
  # Logic for both register and admin creation mixed here
end
```

### Explicit Constraints

Use `accept` to be explicit about what input each action allows:

```elixir
# ✅ Clear constraints
update :update_email do
  accept [:email]
end

# ❌ Vague - takes all inputs
update :update_email do
  default_accept [:name, :email, :password, :role]
end
```

---

[← Back to main](ash-3.7.6.md)
**Version:** 3.7.6
