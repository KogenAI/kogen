# ash - Validations & Changes

## Validations

Validations check whether data meets requirements and return errors if conditions aren't met. Validations "cannot modify the changeset"—they only continue or add an error. They work across all action types: create, update, destroy, and read operations.

### Built-in Validations

Ash provides numerous pre-built validations that work automatically:

#### Presence & Value Checks

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource

  attributes do
    uuid_primary_key :id
    attribute :name, :string
    attribute :email, :string
  end

  actions do
    create :create do
      accept [:name, :email]
      validate present(:name)  # Ensure name is not nil/empty
      validate present(:email)
    end
  end
end
```

#### String Validations

```elixir
defmodule MyApp.Posts.Post do
  use Ash.Resource

  attributes do
    attribute :title, :string
    attribute :slug, :string
  end

  actions do
    create :create do
      accept [:title, :slug]
      validate string_length(:title, min: 3, max: 100)
      validate string_length(:slug, min: 1, max: 50)
      validate match(:slug, ~r/^[a-z0-9-]+$/)  # Only lowercase, numbers, hyphens
    end
  end
end
```

#### Range & Comparison

```elixir
validate compare(:age, greater_than_or_equal_to: 18)
validate compare(:price, less_than: 10000)
validate compare(:end_date, greater_than: :start_date)  # Compare fields
```

#### Enum Validation

```elixir
defmodule MyApp.Events.Event do
  use Ash.Resource

  attributes do
    attribute :status, :atom
  end

  actions do
    create :create do
      validate one_of(:status, [:draft, :scheduled, :published, :archived])
    end
  end
end
```

#### Confirmation

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource

  attributes do
    attribute :email, :string
    attribute :password, :string
  end

  actions do
    create :register do
      accept [:email, :password, :password_confirmation]
      validate confirm(:password, :password_confirmation)
    end
  end
end
```

#### Action Validation

```elixir
validate action_is([:create, :update])  # Only run for specific actions
```

### Custom Validations

Create custom validations by implementing `Ash.Resource.Validation`:

```elixir
defmodule MyApp.Validations.StrongPassword do
  use Ash.Resource.Validation

  def init(opts) do
    {:ok, opts}
  end

  def supports(_type) do
    :changeset
  end

  def validate(changeset, _opts) do
    password = Ash.Changeset.get_attribute(changeset, :password)

    case check_strength(password) do
      :weak ->
        Ash.Changeset.add_error(changeset, field: :password, message: "Password is too weak")
      :strong ->
        changeset
    end
  end

  defp check_strength(password) when is_binary(password) do
    has_upper = String.match?(password, ~r/[A-Z]/)
    has_lower = String.match?(password, ~r/[a-z]/)
    has_digit = String.match?(password, ~r/\d/)
    has_special = String.match?(password, ~r/[!@#$%^&*]/)

    if has_upper and has_lower and has_digit and has_special do
      :strong
    else
      :weak
    end
  end

  defp check_strength(_), do: :weak
end

# Use in resource
actions do
  create :register do
    validate MyApp.Validations.StrongPassword
  end
end
```

### Conditional Validations

Use `where` to run validations only when specific conditions are met:

```elixir
defmodule MyApp.Orders.Order do
  use Ash.Resource

  attributes do
    attribute :status, :atom
    attribute :shipped_date, :date
  end

  actions do
    update :update do
      validate present(:shipped_date), where: [attribute(:status, equals: :shipped)]
    end
  end
end
```

### Validation Efficiency

Use `only_when_valid?` to skip expensive validations until simpler checks pass:

```elixir
actions do
  create :create do
    # Run fast checks first
    validate present(:email)

    # Only run expensive validation after basic checks pass
    validate MyApp.Validations.CheckEmailUniqueness, only_when_valid?: true
  end
end
```

## Changes

Changes are mechanisms for customizing create, update, and destroy action behavior. A change "will take a changeset and return a new changeset." They serve as the resource-layer equivalent to middleware—operating on data transformation rather than validation.

### Key Difference: Changes vs Validations

- **Validations** check requirements and return errors if unmet
- **Changes** actively modify or transform data within changesets

### Built-in Changes

Ash provides pre-made changes for common patterns:

#### Set Attribute

```elixir
defmodule MyApp.Projects.Project do
  use Ash.Resource

  attributes do
    attribute :slug, :string
    attribute :name, :string
  end

  actions do
    create :create do
      accept [:name]
      change set_attribute(:slug, :unslugified_name)  # Set from another attribute
      change set_attribute(:status, :draft)  # Set static value
    end
  end
end
```

#### Relate Actor

Set the current user (actor) as a relationship:

```elixir
defmodule MyApp.Posts.Post do
  use Ash.Resource

  relationships do
    belongs_to :author, MyApp.Accounts.User
  end

  actions do
    create :create do
      accept [:title, :content]
      change relate_actor(:author)  # Set author to current user
    end
  end
end
```

#### Optimistic Lock

Prevent concurrent update conflicts:

```elixir
defmodule MyApp.Documents.Document do
  use Ash.Resource

  attributes do
    attribute :version, :integer
  end

  actions do
    update :update do
      change optimistic_lock(:version)
    end
  end
end
```

#### Manage Relationship

Handle related record operations automatically:

```elixir
defmodule MyApp.Users.User do
  use Ash.Resource

  relationships do
    has_many :posts, MyApp.Posts.Post
  end

  actions do
    update :update do
      change manage_relationship(:posts, on_input: :destroy)
    end
  end
end
```

### Custom Changes

Create custom changes by implementing `Ash.Resource.Change`:

```elixir
defmodule MyApp.Changes.SlugifyName do
  use Ash.Resource.Change

  def init(opts) do
    {:ok, opts}
  end

  def change(changeset, _opts) do
    name = Ash.Changeset.get_attribute(changeset, :name)

    case name do
      nil ->
        changeset
      _ ->
        slug = name
               |> String.downcase()
               |> String.replace(~r/\s+/, "-")
               |> String.replace(~r/[^a-z0-9-]/, "")

        Ash.Changeset.change_attribute(changeset, :slug, slug)
    end
  end
end

# Use in resource
actions do
  create :create do
    change MyApp.Changes.SlugifyName
  end
end
```

### Conditional Changes

Use `where` to apply changes only under specific conditions:

```elixir
defmodule MyApp.Orders.Order do
  use Ash.Resource

  actions do
    update :update do
      # Only update total if status changed to 'completed'
      change calculate_total(),
        where: [attribute(:status, equals: :completed)]
    end
  end
end
```

### Change Ordering

Changes execute in the order declared:

```elixir
actions do
  create :create do
    change set_attribute(:status, :draft)
    change calculate_defaults()  # Runs after setting status
    change send_notification()   # Runs after calculations
  end
end
```

## Combining Validations and Changes

Validations and changes work together in the action lifecycle:

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource

  attributes do
    attribute :email, :string
    attribute :password, :string
    attribute :password_hash, :string, private?: true
  end

  actions do
    create :register do
      accept [:email, :password, :password_confirmation]

      # Validations first (check requirements)
      validate present(:password)
      validate string_length(:password, min: 12)
      validate confirm(:password, :password_confirmation)

      # Changes after (modify data)
      change MyApp.Changes.HashPassword
      change relate_actor(:created_by)
    end
  end
end
```

---

[← Back to main](ash-3.7.6.md)
**Version:** 3.7.6
