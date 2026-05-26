# Recipe: Phoenix Component Attribute Alphabetical Ordering

## Problem

Phoenix components require `attr` declarations to match the parameters used in HEEx templates, but inconsistent ordering between declarations and usage creates maintenance overhead and increases the risk of mismatches. Code review tools like Credo may enforce alphabetical ordering for consistency, but this must be maintained across both the component definition and its usage.

## Solution

Maintain strict alphabetical ordering in both `attr` declarations and HEEx component calls. This ensures consistency, reduces cognitive load during code review, and satisfies code quality tools that enforce alphabetical ordering.

## Implementation

### 1. Component Definition - Alphabetical `attr` Ordering

Always order `attr` declarations alphabetically by attribute name:

```elixir
# ❌ Wrong - Random ordering
defmodule ElixirDropsWeb.DropComponents do
  use Phoenix.Component

  attr :drop, Drop, required: true
  attr :current_user, User, default: nil
  attr :show_edit, :boolean, default: false
  attr :compact, :boolean, default: false

  def drop_card(assigns) do
    # Component implementation
  end
end
```

```elixir
# ✅ Correct - Alphabetical ordering
defmodule ElixirDropsWeb.DropComponents do
  use Phoenix.Component

  attr :compact, :boolean, default: false      # 'c' comes first
  attr :current_user, User, default: nil      # 'c' after 'compact'
  attr :drop, Drop, required: true            # 'd' comes next
  attr :show_edit, :boolean, default: false   # 's' comes last

  def drop_card(assigns) do
    # Component implementation
  end
end
```

### 2. HEEx Template Usage - Alphabetical Parameter Ordering

Order component parameters alphabetically when calling the component:

```heex
<!-- ❌ Wrong - Parameters don't match declaration order -->
<DropComponents.drop_card
  drop={@drop}
  current_user={@current_user}
  show_edit={true}
  compact={false} />
```

```heex
<!-- ✅ Correct - Alphabetical parameter ordering -->
<DropComponents.drop_card
  compact={false}
  current_user={@current_user}
  drop={@drop}
  show_edit={true} />
```

### 3. Enforcement Through Code Review

Create a systematic approach to maintain ordering:

```elixir
# In .credo.exs configuration
{Credo.Check.Readability.StrictModuleLayout, [
  order: [
    :module_attribute,
    :module_directive,
    :attr,        # Ensure attrs are grouped
    :module_function
  ]
]}
```

### 4. Automated Ordering Verification

Use a custom Credo check or pre-commit hook to verify attribute ordering:

```elixir
# Custom verification function
defp verify_attr_ordering(attrs) do
  attr_names = Enum.map(attrs, fn {_, name, _, _} -> to_string(name) end)
  sorted_names = Enum.sort(attr_names)

  if attr_names == sorted_names do
    :ok
  else
    {:error, "Attributes not in alphabetical order: #{inspect(attr_names)} should be #{inspect(sorted_names)}"}
  end
end
```

## Considerations

### Benefits

- **Consistency**: Same ordering pattern across entire codebase
- **Code Review**: Easier to spot missing or incorrect attributes
- **Maintainability**: Predictable attribute location reduces search time
- **Tool Compliance**: Satisfies code quality tools like Credo
- **Merge Conflicts**: Reduces conflicts when multiple developers add attributes

### Trade-offs

- **Manual Effort**: Requires discipline to maintain ordering
- **Initial Migration**: Existing components need to be reordered
- **Learning Curve**: Team needs to adopt new habit
- **No Functional Benefit**: Ordering doesn't affect runtime behavior

### When to Use

- ✅ When code quality tools enforce alphabetical ordering
- ✅ When component APIs are complex with many attributes
- ✅ When multiple developers work on the same components
- ✅ When maintaining large component libraries
- ✅ When consistency is a project priority

### When NOT to Use

- ❌ For very simple components with 1-2 attributes
- ❌ When attribute grouping by functionality is more important
- ❌ For prototype or throwaway code
- ❌ When team strongly prefers semantic ordering

## Example Usage

This pattern was enforced during a Phoenix LiveView feature implementation:

### Before (Inconsistent)

```elixir
# Component definition
attr :drop, Drop, required: true
attr :current_user, User, default: nil

# Template usage - different order
<DropComponents.drop current_user={@current_user} drop={@drop} />
```

**Result**: Credo violations and code review confusion

### After (Consistent)

```elixir
# Component definition - alphabetical
attr :current_user, User, default: nil      # 'c' first
attr :drop, Drop, required: true            # 'd' second

# Template usage - matching alphabetical order
<DropComponents.drop current_user={@current_user} drop={@drop} />
```

**Result**: Clean code review, Credo compliance, easier maintenance

### Code Review Fix Process

1. **Identify Violations**: Credo reports attribute ordering issues
2. **Fix Component Definition**: Reorder `attr` declarations alphabetically
3. **Fix Template Usage**: Reorder component parameters alphabetically
4. **Verify Consistency**: Ensure both definition and usage match
5. **Test**: Confirm component still works correctly

### Real Implementation Example

```elixir
# lib/elixir_drops_web/live/drop_components.ex
defmodule ElixirDropsWeb.DropComponents do
  use Phoenix.Component
  alias ElixirDrops.Accounts.User
  alias ElixirDrops.Drops.Drop

  # ✅ Alphabetical ordering maintained
  attr :current_user, User, default: nil
  attr :drop, Drop, required: true

  def drop(assigns) do
    ~H"""
    <div class="drop-container">
      <h3><%= @drop.title %></h3>
      <%= if @current_user && @current_user.id == @drop.user_id do %>
        <button>Edit</button>
      <% end %>
    </div>
    """
  end
end

# lib/elixir_drops_web/live/drop_live/show.html.heex
<DropComponents.drop current_user={@current_user} drop={@drop} />
```

## Related Recipes

- [Semantic Component API Design](semantic-component-api-design.md) - For designing component interfaces
- [Phoenix Component Migration](phoenix-component-migration.md) - For updating existing components
- [Test Coverage Strategies](test-coverage-strategies.md) - For maintaining component test coverage
