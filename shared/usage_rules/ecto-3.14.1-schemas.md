# ecto - Schemas and Changesets

Ecto schemas are flexible mappers that convert any data source into Elixir structs. They're not limited to database tables—schemas can represent form inputs, API responses, or any structured data. This flexibility means you can use schemas for validation and transformation before persisting to a database.

## Schema Definition

Define schemas using the `Ecto.Schema` module:

```elixir
defmodule MyApp.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :name, :string
    field :email, :string
    field :age, :integer
    field :admin, :boolean, default: false
    timestamps()
  end
end
```

Field types include `:string`, `:integer`, `:boolean`, `:decimal`, `:float`, `:date`, `:time`, `:datetime`, `:binary`, `:map`, and custom types.

## Changesets for Validation

Changesets provide a data structure for validating and transforming data before database operations. They track what changed, validation errors, and the new data:

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:name, :email, :age])
  |> validate_required([:name, :email])
  |> validate_format(:email, ~r/@/)
  |> unique_constraint(:email)
end
```

Key changeset functions:

- `cast/3` - Converts maps into changesets, whitelisting allowed fields
- `validate_required/2` - Ensures specified fields are present and non-empty
- `validate_format/3` - Validates field values against a regex pattern
- `validate_length/3` - Ensures strings/lists meet length requirements
- `validate_number/3` - Validates numeric ranges
- `unique_constraint/2` - Adds a database constraint check

## Separating Input from Domain Models

Avoid using a single schema for both input validation and the domain model. Instead, use separate schemas:

```elixir
# Registration form schema - UI-specific fields
defmodule MyApp.Registration do
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :first_name, :string
    field :last_name, :string
    field :email, :string
    field :password, :string, virtual: true
  end

  def changeset(registration, attrs) do
    registration
    |> cast(attrs, [:first_name, :last_name, :email, :password])
    |> validate_required([:first_name, :last_name, :email, :password])
  end
end

# Domain model schema - database structure
defmodule MyApp.Account do
  use Ecto.Schema

  schema "accounts" do
    field :full_name, :string
    field :email, :string
    field :password_hash, :string
  end
end
```

After validating with the registration schema, transform and validate with the domain schema:

```elixir
def create_account(registration_attrs) do
  with {:ok, registration} <- MyApp.Registration.changeset(%MyApp.Registration{}, registration_attrs) |> Repo.insert(),
       account_attrs <- %{full_name: "#{registration.first_name} #{registration.last_name}", email: registration.email, password_hash: hash(registration.password)},
       {:ok, account} <- MyApp.Account.changeset(%MyApp.Account{}, account_attrs) |> Repo.insert() do
    {:ok, account}
  end
end
```

## Schemaless Validation

For one-off validations without reusable schemas, use schemaless changesets:

```elixir
changeset = Ecto.Changeset.cast(
  {%{}, %{name: :string, email: :string}},
  %{"name" => "John", "email" => "john@example.com"},
  [:name, :email]
)
|> Ecto.Changeset.validate_required([:name, :email])
```

## Custom Validation Functions

Create reusable validation logic with custom functions:

```elixir
def validate_username(changeset) do
  validate_change(changeset, :username, fn _field, value ->
    if String.contains?(value, " ") do
      [username: "cannot contain spaces"]
    else
      []
    end
  end)
end
```

## Applying Validations to Changesets

Chain validations together in changeset functions for clarity:

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:name, :email, :age, :username])
  |> validate_required([:name, :email])
  |> validate_username()
  |> validate_format(:email, ~r/@/)
  |> validate_length(:username, min: 3, max: 20)
  |> unique_constraint(:email)
  |> unique_constraint(:username)
end
```

Ecto checks database constraints only during database operations, not during changeset validation. This separation allows validation to happen before database round-trips.

---

[← Back to main](ecto-3.14.1.md)
**Version:** 3.14.1
