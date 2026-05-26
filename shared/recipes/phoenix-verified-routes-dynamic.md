# Recipe: Phoenix Verified Routes with Dynamic Asset Paths

## Problem

Phoenix verified routes (`~p"/path"`) provide compile-time safety for static assets but fail when using string interpolation like `~p"/images/icons/#{icon_name}.svg"`. The compilation error "path segments after interpolation must begin with /" prevents dynamic asset path generation while maintaining type safety.

## Solution

Create helper functions with explicit pattern matching for all known dynamic paths. This approach maintains compile-time verification while supporting dynamic asset selection, using fail-fast design for unknown assets.

## Implementation

### 1. Create Helper Function with Pattern Matching

Instead of using interpolation in verified routes:

```elixir
# ❌ This fails compilation
def render_icon(assigns) do
  ~H"""
  <img src={~p"/images/icons/#{@icon}.svg"} alt={@icon} />
  """
end
```

Use a helper function with explicit pattern matching:

```elixir
# ✅ This works and maintains compile-time safety
defp icon_path(icon_name) do
  case icon_name do
    "icon-briefcase" -> ~p"/images/icons/icon-briefcase.svg"
    "icon-building" -> ~p"/images/icons/icon-building.svg"
    "icon-cog" -> ~p"/images/icons/icon-cog.svg"
    "icon-user" -> ~p"/images/icons/icon-user.svg"
    "icon-bell" -> ~p"/images/icons/icon-bell.svg"
    # Add all known icons explicitly
  end
end

def render_icon(assigns) do
  ~H"""
  <img src={icon_path(@icon)} alt={@icon} />
  """
end
```

### 2. Function Clause Alternative (More Idiomatic Elixir)

For better performance and readability, use function clauses instead of case statements:

```elixir
defp icon_path("icon-briefcase"), do: ~p"/images/icons/icon-briefcase.svg"
defp icon_path("icon-building"), do: ~p"/images/icons/icon-building.svg"
defp icon_path("icon-cog"), do: ~p"/images/icons/icon-cog.svg"
defp icon_path("icon-user"), do: ~p"/images/icons/icon-user.svg"
defp icon_path("icon-bell"), do: ~p"/images/icons/icon-bell.svg"
# No fallback clause - let it crash for unknown icons
```

### 3. Macro for Repetitive Patterns

For large numbers of assets, consider a macro to reduce boilerplate:

```elixir
defmacro define_icon_paths(icons) do
  clauses = for icon <- icons do
    quote do
      defp icon_path(unquote(icon)), do: unquote(~p"/images/icons/#{icon}.svg")
    end
  end

  {:__block__, [], clauses}
end

# Usage:
define_icon_paths([
  "icon-briefcase",
  "icon-building",
  "icon-cog",
  "icon-user",
  "icon-bell"
])
```

## Considerations

### Benefits

- **Compile-time safety**: All paths verified at compilation
- **Explicit asset management**: Forces documentation of all available assets
- **Fail-fast design**: Unknown assets cause immediate failures, not runtime errors
- **Type safety**: Phoenix verified routes ensure paths are valid

### Trade-offs

- **Maintenance overhead**: Must update helper function when adding new assets
- **No dynamic discovery**: Cannot use assets not explicitly listed
- **Code duplication**: Each asset requires explicit pattern matching

### When to Use

- ✅ When you have a known, finite set of assets (icons, images)
- ✅ When compile-time safety is more important than runtime flexibility
- ✅ When assets are managed as part of design system

### When NOT to Use

- ❌ When assets are user-uploaded or dynamically generated
- ❌ When asset names come from external sources (database, API)
- ❌ When you need completely dynamic asset loading

### Important Guidelines

- **No fallback cases**: Avoid `_ -> "/default.svg"` patterns that hide missing assets
- **Consistent naming**: Use predictable naming patterns like `"icon-{name}"`
- **Exhaustive patterns**: Include all known assets explicitly
- **Documentation**: Comment the helper function with asset management strategy

## Example Usage

This pattern was successfully applied in a Phoenix LiveView company settings implementation:

```elixir
# In navigation drawer component
def navigation_drawer(assigns) do
  ~H"""
  <nav class="space-y-2">
    <.nav_item icon="icon-briefcase" text="Jobs" href={~p"/jobs"} />
    <.nav_item icon="icon-user" text="Medical Personnel" href={~p"/team"} />
    <.nav_item icon="icon-cog" text="Settings" href={~p"/settings"} />
  </nav>
  """
end

# Helper function ensures all navigation icons exist at compile time
defp icon_path("icon-briefcase"), do: ~p"/images/icons/icon-briefcase.svg"
defp icon_path("icon-user"), do: ~p"/images/icons/icon-user.svg"
defp icon_path("icon-cog"), do: ~p"/images/icons/icon-cog.svg"

def nav_item(assigns) do
  ~H"""
  <a href={@href} class="flex items-center space-x-3">
    <img src={icon_path(@icon)} alt="" class="w-5 h-5" />
    <span><%= @text %></span>
  </a>
  """
end
```

## Related Recipes

- [Figma to Code with MCP](figma-to-code-mcp.md) - For extracting and managing design assets
- [Semantic Component API Design](semantic-component-api-design.md) - For designing component interfaces that work with this pattern
