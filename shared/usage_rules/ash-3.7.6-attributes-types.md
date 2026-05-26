# ash - Attributes & Types

## Attributes

Attributes define the name, type, and configuration of properties stored on a resource. In SQL-based systems, attributes map to database table columns. Each attribute specifies its type, constraints, defaults, and write accessibility.

### Basic Attribute Definition

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource

  attributes do
    # Primary key
    uuid_primary_key :id

    # Simple attributes with types
    attribute :name, :string
    attribute :email, :string
    attribute :age, :integer
    attribute :is_active, :boolean
    attribute :inserted_at, :utc_datetime_usec

    # With constraints and defaults
    attribute :status, :atom, one_of: [:active, :suspended], default: :active
    attribute :role, :string, allow_nil?: false
    attribute :created_at, :utc_datetime_usec, default: &DateTime.utc_now/0
  end
end
```

### Common Options

- **`type`** - Data type (`:string`, `:integer`, `:boolean`, `:atom`, `:uuid`, `:date`, `:datetime`, `:utc_datetime_usec`, etc.)
- **`primary_key?`** - Whether this attribute is the primary key
- **`writable?`** - Controls if the attribute can be modified (defaults to `true`)
- **`default`** - Initial value or function that generates one
- **`allow_nil?`** - Whether null values are permitted (defaults to `true`)
- **`match_other_defaults?`** - Synchronize default behavior across create/update
- **`private?`** - If `true`, attribute won't be exposed in API responses or be settable

## Special Attribute Shortcuts

Ash provides convenience shortcuts for common patterns:

### UUID Primary Key

```elixir
# Generates UUIDs automatically
uuid_primary_key :id
```

### Integer Primary Key

```elixir
# Creates auto-incrementing ID (SQL data layers only)
integer_primary_key :id
```

### Timestamps

```elixir
# Automatic creation timestamp
create_timestamp :created_at

# Automatic update timestamp
update_timestamp :updated_at
```

These are non-writable by default and automatically managed by Ash.

## Common Data Types

### Primitives

- `:string` - Text data
- `:integer` - Whole numbers
- `:float` - Decimal numbers
- `:boolean` - True/false values
- `:atom` - Elixir atoms

### Identifiers

- `:uuid` - UUID format
- `:binary` - Binary data

### Date/Time

- `:date` - Date only
- `:datetime` - DateTime with timezone
- `:utc_datetime_usec` - UTC datetime with microsecond precision
- `:time` - Time only

### Advanced

- `:term` - Any Elixir term (use sparingly)
- `:decimal` - High-precision decimal (for financial data)
- `:map` - JSON-like maps
- `:list` - Lists with element type specification

## Attribute Constraints

### Value Constraints

```elixir
attribute :status, :atom, one_of: [:draft, :published, :archived]
attribute :age, :integer, min: 0, max: 150
attribute :email, :string, min_length: 5, max_length: 255
```

### Nullability

```elixir
# Allow nil (default)
attribute :middle_name, :string, allow_nil?: true

# Required attribute
attribute :last_name, :string, allow_nil?: false
```

### Write Control

```elixir
# Can be created but not updated
attribute :created_by, :string, writable?: false

# Use for system-managed fields
attribute :version, :integer, writable?: false, default: 0
```

## Attribute Defaults

### Static Defaults

```elixir
attribute :country, :string, default: "US"
attribute :is_verified, :boolean, default: false
```

### Dynamic Defaults

Use function references for values that change:

```elixir
attribute :id, :uuid, default: &Ash.UUID.generate/0
attribute :created_at, :utc_datetime_usec, default: &DateTime.utc_now/0
attribute :random_code, :string, default: &MyApp.Crypto.generate_code/0
```

### Match Other Defaults

Ensure defaults are consistent across create and update:

```elixir
attribute :updated_at,
  :utc_datetime_usec,
  default: &DateTime.utc_now/0,
  match_other_defaults?: true
```

## Best Practices

### Use UUIDs Over Auto-Increment IDs

```elixir
# ✅ Preferred
uuid_primary_key :id

# ❌ Avoid for most cases
integer_primary_key :id
```

Reasons: UUIDs are globally unique, easier to distribute, and safer for data migrations.

### Use Computed Values with Calculations

For derived data, use Calculations instead of stored attributes:

```elixir
# ❌ Don't store computed values
attribute :full_name, :string

# ✅ Use calculations instead
calculations do
  calculate :full_name, :string, expr(first_name <> " " <> last_name)
end
```

### Private Sensitive Attributes

```elixir
# Don't expose password_hash in API responses
attribute :password_hash, :string, private?: true
```

### Consistency with Timestamps

```elixir
defmodule MyApp.Event do
  use Ash.Resource

  attributes do
    uuid_primary_key :id
    attribute :title, :string

    create_timestamp :created_at
    update_timestamp :updated_at
  end
end
```

---

[← Back to main](ash-3.7.6.md)
**Version:** 3.7.6
