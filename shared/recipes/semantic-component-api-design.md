# Recipe: Semantic Component API Design

## Problem

How to design component APIs that are intuitive, maintainable, and reduce cognitive load for developers? Traditional parameter-heavy component systems often lead to confusion and poor developer experience.

## Solution

Design components with semantic, intuitive names that clearly communicate their purpose, avoiding parameter-heavy APIs in favor of specific component functions. This approach reduces cognitive load and makes components self-documenting.

## Implementation

### 1. Semantic Component Naming

Replace parameter-based systems with semantic component names:

```elixir
# BAD: Parameter-heavy approach
attr :level, :string, default: "h1", values: ["h1", "h2", "h3", "h4", "h5", "h6"]
attr :size, :string, default: "large", values: ["small", "medium", "large"]
attr :weight, :string, default: "bold", values: ["normal", "medium", "bold"]

def heading(assigns) do
  ~H"""
  <h1 :if={@level == "h1"} class={heading_classes(@size, @weight)}>
    <%= render_slot(@inner_block) %>
  </h1>
  <!-- Complex conditional logic for each level -->
  """
end

# GOOD: Semantic approach
def heading(assigns) do
  ~H"""
  <h1 class="text-h1 font-bold text-gray-900"><%= render_slot(@inner_block) %></h1>
  """
end

def section_heading(assigns) do
  ~H"""
  <h2 class="text-h2 font-semibold text-gray-900"><%= render_slot(@inner_block) %></h2>
  """
end

def subsection_heading(assigns) do
  ~H"""
  <h3 class="text-h3 font-medium text-gray-900"><%= render_slot(@inner_block) %></h3>
  """
end
```

### 2. Typography Component System

Create a complete semantic typography system:

```elixir
# lib/my_app_web/components/core/typography.ex
defmodule MyAppWeb.Components.Core.Typography do
  use Phoenix.Component

  @type assigns :: Phoenix.LiveView.Socket.assigns()
  @type rendered :: Phoenix.LiveView.Rendered.t()

  attr :class, :any, default: []
  slot :inner_block, required: true

  @spec heading(assigns()) :: rendered()
  def heading(assigns) do
    ~H"""
    <h1 class={["text-h1 font-bold text-gray-900", @class]}>
      <%= render_slot(@inner_block) %>
    </h1>
    """
  end

  @spec section_heading(assigns()) :: rendered()
  def section_heading(assigns) do
    ~H"""
    <h2 class={["text-h2 font-semibold text-gray-900", @class]}>
      <%= render_slot(@inner_block) %>
    </h2>
    """
  end

  @spec subsection_heading(assigns()) :: rendered()
  def subsection_heading(assigns) do
    ~H"""
    <h3 class={["text-h3 font-medium text-gray-900", @class]}>
      <%= render_slot(@inner_block) %>
    </h3>
    """
  end

  @spec subtitle(assigns()) :: rendered()
  def subtitle(assigns) do
    ~H"""
    <p class={["text-body text-gray-600", @class]}>
      <%= render_slot(@inner_block) %>
    </p>
    """
  end

  @spec text(assigns()) :: rendered()
  def text(assigns) do
    ~H"""
    <p class={["text-body text-gray-700", @class]}>
      <%= render_slot(@inner_block) %>
    </p>
    """
  end

  @spec small_text(assigns()) :: rendered()
  def small_text(assigns) do
    ~H"""
    <p class={["text-body-sm text-gray-600", @class]}>
      <%= render_slot(@inner_block) %>
    </p>
    """
  end

  @spec caption(assigns()) :: rendered()
  def caption(assigns) do
    ~H"""
    <p class={["text-caption text-gray-500", @class]}>
      <%= render_slot(@inner_block) %>
    </p>
    """
  end
end
```

### 3. Token-First Component Design

Components should use built-in design tokens, with classes only for overrides:

```elixir
# BAD: Requiring classes for basic functionality
~H"""
<.text class="text-gray-700 text-base leading-relaxed">Content</.text>
"""

# GOOD: Built-in styling, classes for overrides only
~H"""
<.text>Content</.text>                           <!-- Default styling -->
<.text class="mt-4">Content with spacing</.text> <!-- Override for spacing -->
<.text class="font-bold">Bold content</.text>    <!-- Override for emphasis -->
<.text class="text-red-600">Error text</.text>   <!-- Override for color -->
"""
```

### 4. Button Component with Semantic Variants

Design button variants that communicate intent clearly:

```elixir
# lib/my_app_web/components/core/button.ex
defmodule MyAppWeb.Components.Core.Button do
  use Phoenix.Component

  attr :variant, :string, default: "primary",
    values: ["primary", "secondary", "danger", "primary_light", "primary_outline"]
  attr :size, :string, default: "md", values: ["sm", "md", "lg"]
  attr :type, :string, default: "button"
  attr :disabled, :boolean, default: false
  attr :class, :any, default: []

  # Navigation attributes
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :href, :string, default: nil
  attr :rest, :global

  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <.link
      :if={@navigate || @patch || @href}
      navigate={@navigate}
      patch={@patch}
      href={@href}
      class={[
        button_base_classes(),
        button_size_classes(@size),
        button_variant_classes(@variant),
        @disabled && "opacity-50 cursor-not-allowed",
        @class
      ]}
      {@rest}
    >
      <%= render_slot(@inner_block) %>
    </.link>

    <button
      :if={!@navigate && !@patch && !@href}
      type={@type}
      disabled={@disabled}
      class={[
        button_base_classes(),
        button_size_classes(@size),
        button_variant_classes(@variant),
        @disabled && "opacity-50 cursor-not-allowed",
        @class
      ]}
      {@rest}
    >
      <%= render_slot(@inner_block) %>
    </button>
    """
  end

  defp button_base_classes do
    "inline-flex items-center justify-center font-medium transition-colors " <>
    "focus:outline-none focus:ring-2 focus:ring-offset-2"
  end

  defp button_size_classes("sm"), do: "px-3 py-1.5 text-sm rounded"
  defp button_size_classes("md"), do: "px-4 py-2 text-sm rounded-md"
  defp button_size_classes("lg"), do: "px-6 py-3 text-base rounded-lg"

  defp button_variant_classes("primary"),
    do: "bg-primary-600 text-white hover:bg-primary-700 focus:ring-primary-500"
  defp button_variant_classes("secondary"),
    do: "bg-gray-200 text-gray-900 hover:bg-gray-300 focus:ring-gray-500"
  defp button_variant_classes("danger"),
    do: "bg-red-600 text-white hover:bg-red-700 focus:ring-red-500"
  defp button_variant_classes("primary_light"),
    do: "bg-primary-50 text-primary-700 hover:bg-primary-100 focus:ring-primary-500"
  defp button_variant_classes("primary_outline"),
    do: "border border-primary-600 text-primary-600 hover:bg-primary-50 focus:ring-primary-500"
end
```

### 5. Form Components with Polymorphic Input

Create intelligent form components that adapt based on type:

```elixir
# lib/my_app_web/components/core/form.ex
defmodule MyAppWeb.Components.Core.Form do
  use Phoenix.Component

  attr :type, :string, default: "text"
  attr :field, Phoenix.HTML.FormField
  attr :placeholder, :string, default: nil
  attr :class, :any, default: []
  attr :rest, :global

  def input(assigns) do
    ~H"""
    <div class="space-y-1">
      <.label :if={@field.field != :hidden} for={@field.id}>
        <%= Phoenix.Naming.humanize(@field.field) %>
      </.label>

      <!-- Text inputs -->
      <input
        :if={@type in ["text", "email", "password", "number", "tel", "url", "search", "hidden"]}
        type={@type}
        name={@field.name}
        id={@field.id}
        value={Phoenix.HTML.Form.normalize_value(@type, @field.value)}
        placeholder={@placeholder}
        class={[input_classes(), @class]}
        {@rest}
      />

      <!-- Textarea -->
      <textarea
        :if={@type == "textarea"}
        name={@field.name}
        id={@field.id}
        placeholder={@placeholder}
        class={[input_classes(), "min-h-[100px]", @class]}
        {@rest}
      ><%= Phoenix.HTML.Form.normalize_value("textarea", @field.value) %></textarea>

      <!-- Select -->
      <select
        :if={@type == "select"}
        name={@field.name}
        id={@field.id}
        class={[input_classes(), @class]}
        {@rest}
      >
        <option value="">Select an option</option>
        <%= render_slot(@inner_block) %>
      </select>

      <.error :for={msg <- Enum.map(@field.errors, &translate_error(&1))}>
        <%= msg %>
      </.error>
    </div>
    """
  end

  defp input_classes do
    "block w-full rounded-md border-gray-300 shadow-sm " <>
    "focus:border-primary-500 focus:ring-primary-500 sm:text-sm"
  end
end
```

### 6. Usage Examples

Show clear, intuitive usage patterns:

```elixir
# Typography usage - self-documenting
~H"""
<.heading>Main Page Title</.heading>
<.subtitle>This page shows the user dashboard</.subtitle>

<.section_heading>Recent Activity</.section_heading>
<.text>Here are your recent activities and updates.</.text>
<.small_text>Last updated 5 minutes ago</.small_text>
<.caption>Data refreshes every 2 minutes</.caption>
"""

# Button usage - clear intent
~H"""
<.button variant="primary" navigate="/dashboard">Go to Dashboard</.button>
<.button variant="secondary">Cancel</.button>
<.button variant="danger">Delete Account</.button>
<.button variant="primary_outline" size="sm">Edit</.button>
"""

# Form usage - intelligent adaptation
~H"""
<.input field={@form[:email]} type="email" placeholder="Enter your email" />
<.input field={@form[:message]} type="textarea" placeholder="Your message" />
<.input field={@form[:country]} type="select">
  <option value="US">United States</option>
  <option value="CA">Canada</option>
</.input>
"""
```

## Considerations

### API Design Principles

- **Semantic over parametric**: Use meaningful component names instead of parameter combinations
- **Single responsibility**: Each component should have one clear purpose
- **Intuitive usage**: Component names should clearly indicate their intended use
- **No cognitive load**: Developers shouldn't need to remember parameter values

### Component Architecture

- **Built-in styling**: Components should work with minimal or no classes
- **Override flexibility**: Allow classes for spacing, emphasis, and specific overrides
- **Design token integration**: Use design tokens for consistent theming
- **Type safety**: Define proper types for all component attributes

### Migration Considerations

- **Gradual adoption**: Can be implemented alongside existing component systems
- **Backward compatibility**: Use delegation to maintain existing APIs during transition
- **Developer feedback**: Listen to developer experience feedback for improvements
- **Documentation**: Provide clear examples and usage patterns

### Performance

- **Compilation efficiency**: Semantic components often compile faster than parameter-heavy ones
- **Runtime performance**: No conditional logic for styling decisions
- **Bundle size**: May result in slightly larger components but better developer experience
- **Caching**: More specific component functions can be better cached

## Example Usage

From the BemedaPersonal frontend reorganization:

```elixir
# Before: Confusing parameter-based API
<.heading level="h2" size="large" weight="semibold">Section Title</.heading>
<.text variant="body" color="muted" size="small">Helper text</.text>

# After: Intuitive semantic API
<.section_heading>Section Title</.section_heading>
<.small_text>Helper text</.small_text>
```

Results achieved:

- **Zero confusion**: Developers immediately understand component purpose
- **Faster development**: No need to reference documentation for parameter values
- **Better maintainability**: Self-documenting component calls
- **Consistent styling**: Built-in design tokens ensure visual consistency

## Related Recipes

- **Phoenix Component Migration with Backward Compatibility**: For migrating existing systems
- **Design Token Configuration**: For implementing token-first styling
- **Component Testing Strategies**: For testing semantic component systems
