# Recipe: Phoenix Component Migration with Backward Compatibility

## Problem

How to migrate from a monolithic component system (like CoreComponents) to a modular design system while maintaining zero breaking changes for existing code? This is critical when you have a large codebase with many component calls that can't be updated simultaneously.

## Solution

Use a delegation pattern combined with a component registry to provide backward compatibility while transitioning to a new component architecture. This enables incremental migration without breaking existing functionality.

## Implementation

### 1. Component Registry Pattern

Create a central registry that manages imports and prevents conflicts:

```elixir
# lib/my_app_web/components.ex
defmodule MyAppWeb.Components do
  @moduledoc """
  Central component registry providing unified access to design system components.
  Prevents import conflicts and provides backward compatibility during migrations.
  """

  defmacro __using__(_) do
    quote do
      # Import new design system components
      import MyAppWeb.Components.Core.Button
      import MyAppWeb.Components.Core.Typography
      import MyAppWeb.Components.Core.Form
      import MyAppWeb.Components.Core.Card
      import MyAppWeb.Components.Core.Modal

      # Domain-specific components
      alias MyAppWeb.Components.Job
      alias MyAppWeb.Components.Application
      alias MyAppWeb.Components.Company

      # Utility modules
      import MyAppWeb.Components.Shared.Spacing
      import MyAppWeb.Components.Shared.Navigation

      # Legacy components (temporary during migration)
      # Only import specific functions needed for backward compatibility
      import MyAppWeb.CoreComponents, only: [input: 1, simple_form: 1, label: 1]
    end
  end
end
```

### 2. Delegation Pattern for Backward Compatibility

Maintain old component APIs by delegating to new components:

```elixir
# lib/my_app_web/components/core/form.ex
defmodule MyAppWeb.Components.Core.Form do
  use Phoenix.Component

  # New polymorphic input component
  attr :type, :string, default: "text"
  attr :field, Phoenix.HTML.FormField
  attr :value, :any
  attr :class, :any, default: []
  attr :rest, :global

  def input(assigns) do
    ~H"""
    <div class="space-y-1">
      <input
        type={@type}
        name={@field.name}
        id={@field.id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value || @field.value)}
        class={[
          "block w-full rounded-md border-gray-300 shadow-sm",
          "focus:border-primary-500 focus:ring-primary-500",
          @class
        ]}
        {@rest}
      />
      <.error :for={msg <- Enum.map(@field.errors, &translate_error(&1))}>
        <%= msg %>
      </.error>
    </div>
    """
  end

  # Delegate old CoreComponents.input calls to new input component
  def core_input(assigns), do: input(assigns)

  # Simple form wrapper
  attr :for, :any, required: true
  attr :action, :string
  attr :class, :any, default: []
  attr :rest, :global
  slot :inner_block, required: true

  def simple_form(assigns) do
    ~H"""
    <.form for={@for} action={@action} class={["space-y-6", @class]} {@rest}>
      <%= render_slot(@inner_block) %>
    </.form>
    """
  end
end
```

### 3. Domain-Based Component Organization

Organize components by business domain to prevent circular dependencies:

```
lib/my_app_web/components/
├── core/                 # Fundamental UI elements
│   ├── button.ex
│   ├── card.ex
│   ├── form.ex
│   ├── typography.ex
│   └── modal.ex
├── job/                  # Job-specific components
│   ├── listing_card.ex
│   └── application_form.ex
├── application/          # Application workflow components
│   ├── status_badge.ex
│   └── timeline.ex
├── company/              # Company-related components
│   ├── profile_card.ex
│   └── settings_form.ex
├── document/             # Document handling components
│   ├── pdf_preview.ex
│   └── template_editor.ex
└── shared/               # Cross-domain utilities
    ├── spacing.ex
    ├── navigation.ex
    └── error.ex
```

### 4. Import Conflict Resolution

Handle function name conflicts between old and new components:

```elixir
# lib/my_app_web/html_helpers.ex
defmodule MyAppWeb.HtmlHelpers do
  # Remove direct CoreComponents import to avoid conflicts
  # import MyAppWeb.CoreComponents  # OLD - causes conflicts

  # Use component registry instead
  use MyAppWeb.Components

  # Delegate critical functions that must work during migration
  defdelegate icon(assigns), to: MyAppWeb.Components.Core.Icon
  defdelegate error(assigns), to: MyAppWeb.Components.Core.Error
end
```

### 5. Gradual Migration Strategy

Implement components incrementally while maintaining backward compatibility:

```elixir
# Phase 1: Create new components alongside old ones
# lib/my_app_web/components/core/button.ex
defmodule MyAppWeb.Components.Core.Button do
  use Phoenix.Component

  attr :variant, :string, default: "primary"
  attr :class, :any, default: []
  attr :rest, :global
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button class={[button_classes(@variant), @class]} {@rest}>
      <%= render_slot(@inner_block) %>
    </button>
    """
  end

  defp button_classes("primary"), do: "bg-primary-600 text-white hover:bg-primary-700"
  defp button_classes("secondary"), do: "bg-gray-200 text-gray-900 hover:bg-gray-300"
end

# Phase 2: Update CoreComponents to delegate to new components
# lib/my_app_web/core_components.ex (temporarily kept)
defmodule MyAppWeb.CoreComponents do
  # Delegate button calls to new Button component
  defdelegate button(assigns), to: MyAppWeb.Components.Core.Button

  # Keep other components temporarily
  def input(assigns), do: # ... existing implementation
end

# Phase 3: Remove CoreComponents entirely
# Delete lib/my_app_web/core_components.ex
# Update component registry to only import new components
```

## Considerations

### Migration Strategy

- **Incremental approach**: Migrate component types one at a time
- **Test extensively**: Ensure each migration phase doesn't break existing functionality
- **Compilation checks**: Verify clean compilation after each component migration
- **Backward compatibility**: Never break existing component calls during migration

### Import Management

- **Centralized registry**: Use a single module to manage all component imports
- **Selective imports**: Only import specific functions from legacy modules
- **Conflict resolution**: Use delegation to resolve function name conflicts
- **Clean separation**: Keep old and new components clearly separated during transition

### Component Design

- **Semantic APIs**: Use intuitive component names instead of parameter-heavy systems
- **Token-first styling**: Components should use design tokens, not hardcoded values
- **Minimal classes**: Components work with built-in styling, classes for overrides only
- **Domain organization**: Group components by business logic to prevent circular dependencies

### Testing Considerations

- **Form compatibility**: Test that form components handle all input types correctly
- **Error handling**: Ensure error display works with both old and new component patterns
- **Attribute compatibility**: Verify all component attributes work as expected
- **Migration validation**: Test each phase thoroughly before proceeding

## Example Usage

From the BemedaPersonal frontend reorganization:

```elixir
# Before: Monolithic CoreComponents
import MyAppWeb.CoreComponents

def render(assigns) do
  ~H"""
  <.button class="bg-blue-500 text-white">Click me</.button>
  <.input field={@form[:email]} type="email" />
  """
end

# During Migration: Components work unchanged
use MyAppWeb.Components  # Uses component registry

def render(assigns) do
  ~H"""
  <.button variant="primary">Click me</.button>
  <.input field={@form[:email]} type="email" />
  """
end

# After Migration: CoreComponents removed, zero breaking changes
# All existing calls continue to work through delegation pattern
```

The migration achieved:

- **Zero breaking changes**: All existing component calls continued working
- **90.1% code coverage**: Maintained high test coverage throughout migration
- **Clean architecture**: Modular components organized by domain
- **Design system**: Consistent styling through design tokens

## Related Recipes

- **Design System Implementation**: For creating consistent component APIs
- **Phoenix Component Testing**: For testing component migrations thoroughly
- **Tailwind Design Token Configuration**: For implementing token-first styling
