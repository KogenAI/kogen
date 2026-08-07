# ecto - Embedded Schemas and Nested Data

Embedded schemas enable you to define and validate structured data that exists in memory or persists as JSON in the database. They're ideal for managing intermediate state, complex nested structures, and data that doesn't warrant separate tables.

## Defining Embedded Schemas

Use `embeds_one` or `embeds_many` to define nested structures within a parent schema:

```elixir
defmodule MyApp.Address do
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :street, :string
    field :city, :string
    field :postal_code, :string
  end

  def changeset(address, attrs) do
    address
    |> cast(attrs, [:street, :city, :postal_code])
    |> validate_required([:street, :city])
  end
end

defmodule MyApp.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :name, :string
    embeds_one :address, MyApp.Address
    embeds_many :contacts, MyApp.Contact
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name])
    |> cast_embed(:address)
    |> cast_embed(:contacts)
  end
end
```

## Inline Embedded Definition

For simple or single-use embeddings, define schemas inline:

```elixir
defmodule MyApp.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :name, :string

    embeds_one :address, Address do
      field :street, :string
      field :city, :string
    end
  end
end
```

This automatically generates a module at `MyApp.User.Address` in the parent's scope.

## Persistence to Database

Embedded schemas don't require separate database tables. Store them as JSON using the `:map` type in migrations:

```elixir
create table(:users) do
  add :name, :string
  add :address, :map
  add :contacts, {:array, :map}
  timestamps()
end
```

Most databases represent maps as JSON or JSONB, allowing efficient storage and retrieval. PostgreSQL's JSONB support enables indexing and querying nested fields.

## Validation of Embedded Data

Define `changeset/2` functions for both parent and embedded schemas. Validation failures in embedded schemas automatically propagate to the parent changeset:

```elixir
defmodule MyApp.Contact do
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :type, :string
    field :value, :string
  end

  def changeset(contact, attrs) do
    contact
    |> cast(attrs, [:type, :value])
    |> validate_required([:type, :value])
    |> validate_inclusion(:type, ["email", "phone", "social"])
  end
end

defmodule MyApp.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :name, :string
    embeds_many :contacts, MyApp.Contact
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name])
    |> cast_embed(:contacts)  # Automatically validates all contacts
  end
end
```

If any contact fails validation, the entire user changeset becomes invalid.

## Querying Embedded Data

Once persisted, query embedded fields using bracket notation:

```elixir
import Ecto.Query

# Query users by embedded field value
from u in MyApp.User,
  where: u.address["city"] == "New York"

# For JSONB in PostgreSQL, use @> operator via fragment
from u in MyApp.User,
  where: fragment("? @> ?", u.address, ^%{"city" => "New York"})
```

Ecto automatically constructs appropriate jsonpath queries for JSONB-capable databases like PostgreSQL, enabling efficient filtering.

## Using Embedded Schemas for Forms

Embedded schemas excel for validating form data without persistence:

```elixir
defmodule MyApp.RegistrationForm do
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :first_name, :string
    field :last_name, :string
    field :email, :string
    field :password, :string, virtual: true
    field :password_confirmation, :string, virtual: true

    embeds_one :billing_address, Address do
      field :street, :string
      field :city, :string
      field :postal_code, :string
    end
  end

  def changeset(form, attrs) do
    form
    |> cast(attrs, [:first_name, :last_name, :email, :password, :password_confirmation])
    |> validate_required([:first_name, :last_name, :email, :password])
    |> validate_confirmation(:password)
    |> cast_embed(:billing_address, with: &address_changeset/2)
  end

  defp address_changeset(address, attrs) do
    address
    |> cast(attrs, [:street, :city, :postal_code])
    |> validate_required([:street, :city])
  end
end
```

## Reusability Across Schemas

Embedded schemas defined as separate modules can be embedded by multiple parent schemas:

```elixir
defmodule MyApp.Organization do
  use Ecto.Schema
  schema "organizations" do
    field :name, :string
    embeds_one :billing_address, MyApp.Address
    embeds_one :shipping_address, MyApp.Address
  end
end

defmodule MyApp.User do
  use Ecto.Schema
  schema "users" do
    field :name, :string
    embeds_one :address, MyApp.Address
  end
end
```

Both organizations and users can use the same `MyApp.Address` schema, avoiding duplication.

## Persistence Agnostic

Embedded schemas work identically whether persisted to a database or kept in memory. This makes them ideal for intermediate data transformation:

```elixir
# Create without saving to database
address = MyApp.Address.changeset(%MyApp.Address{}, %{street: "123 Main", city: "NYC"})

# Validate
case address do
  %Ecto.Changeset{valid?: true} -> ...
  %Ecto.Changeset{valid?: false} -> ...
end
```

---

[← Back to main](ecto-3.14.1.md)
**Version:** 3.14.1
