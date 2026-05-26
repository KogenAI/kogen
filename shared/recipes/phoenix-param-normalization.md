# Recipe: Safe Parameter Normalization with FilterUtils Pattern

## Problem

Web applications frequently need to convert URL query parameters (strings) to typed values (atoms, booleans, integers) for database queries. Naive approaches using `String.to_atom/1` create security vulnerabilities by allowing arbitrary atom creation, leading to memory exhaustion attacks.

## Solution

Use an embedded schema with changeset validation to define allowed parameters, then convert via a utility module that provides whitelist-based atom conversion and type normalization.

## Implementation

### 1. Define an Embedded Schema for Filters

```elixir
defmodule MyApp.JobFilter do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :search, :string
    field :location, :string
    field :remote_allowed, :boolean
    field :employment_type, Ecto.Enum, values: [:full_time, :part_time, :contract]
    field :company_id, :binary_id
  end

  def changeset(filter, params) do
    filter
    |> cast(params, [:search, :location, :remote_allowed, :employment_type, :company_id])
    |> validate_length(:search, min: 2)
  end
end
```

### 2. Create FilterUtils Module

```elixir
defmodule MyApp.FilterUtils do
  @doc """
  Safely converts changeset params to atoms using only valid schema fields.
  Filters out nil/empty values and normalizes boolean strings.
  """
  def changeset_to_params(changeset) do
    changeset.changes
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Enum.into(%{})
  end

  def normalize_boolean_params(params) do
    Enum.reduce(params, %{}, fn {key, value}, acc ->
      normalized_value = case value do
        "true" -> true
        "false" -> false
        other -> other
      end
      Map.put(acc, key, normalized_value)
    end)
  end
end
```

### 3. Apply Pattern in LiveView

```elixir
defmodule MyAppWeb.JobLive.Index do
  use MyAppWeb, :live_view
  alias MyApp.{Jobs, FilterUtils}

  def handle_params(params, _url, socket) do
    {:noreply, assign_filter_params(socket, params)}
  end

  defp assign_filter_params(socket, params) do
    # Create filter changeset for validation and type conversion
    filter = %MyApp.JobFilter{}
    changeset = MyApp.JobFilter.changeset(filter, params)

    # Convert to safe atom-keyed params
    normalized_params =
      changeset
      |> FilterUtils.changeset_to_params()
      |> FilterUtils.normalize_boolean_params()

    # Use for database queries
    jobs = Jobs.list_jobs(normalized_params)

    socket
    |> assign(:filter_params, params)
    |> assign(:jobs, jobs)
  end
end
```

## Considerations

### Security Benefits

- **Prevents atom exhaustion attacks**: Only schema-defined fields become atoms
- **Type validation**: Ecto changeset validates data types before conversion
- **Input sanitization**: Invalid values are filtered out automatically

### Performance Benefits

- **Reduced memory usage**: No arbitrary atoms created
- **Efficient queries**: Only valid parameters reach the database layer
- **Early validation**: Catches invalid parameters at the boundary

### When to Use This Pattern

- ✅ URL query parameter processing in web applications
- ✅ API parameter validation and normalization
- ✅ Form submission handling with mixed data types
- ✅ Any scenario involving string-to-typed-value conversion

### When NOT to Use This Pattern

- ❌ Internal application logic where atom keys are already known safe
- ❌ Simple cases with 1-2 parameters where overhead exceeds benefit
- ❌ Performance-critical code paths where changeset overhead is problematic

### Common Pitfalls

- **Forgetting boolean normalization**: URL params are strings; "false" != false
- **Not filtering empty values**: Empty strings can cause validation failures
- **Bypassing validation**: Never convert params to atoms without changeset validation
- **Missing required fields**: Some filters might need default values

## Example Usage

This pattern was successfully applied in the job-posting-figma feature where URL parameters needed safe conversion for database filtering:

```elixir
# Before (vulnerable):
params = %{"remote_allowed" => "true", "employment_type" => "full_time"}
atom_params = for {k, v} <- params, into: %{}, do: {String.to_atom(k), v} # DANGEROUS

# After (safe):
filter = %JobFilter{}
changeset = JobFilter.changeset(filter, params)
safe_params = FilterUtils.changeset_to_params(changeset) # Safe atom conversion
```

The refactoring eliminated custom parameter normalization code and leveraged existing, battle-tested patterns for type conversion and validation.

## Related Recipes

- [Phoenix LiveView Testing Patterns](./phoenix-liveview-testing-patterns.md)
- [Ecto Schema Design for Security](./ecto-schema-security-patterns.md)
