# phoenix_live_view - Client Interop & JavaScript

## Phoenix.LiveView.JS Overview

`Phoenix.LiveView.JS` provides a command builder for client-side operations that execute without server round-trips. These operations manipulate the DOM, apply animations, dispatch events, and push data to the server with enhanced options.

## DOM Manipulation Commands

### Class Management

```elixir
# Add class to element
JS.add_class("active", to: ".menu-item")

# Remove class
JS.remove_class("hidden", to: "#modal")

# Toggle class
JS.toggle_class("expanded", to: ".panel")
```

### Attribute Management

```elixir
# Set attribute
JS.set_attribute({"disabled", "disabled"}, to: "button")

# Remove attribute
JS.remove_attribute("disabled", to: "button")

# Toggle attribute
JS.toggle_attribute({"aria-expanded", "true"}, to: ".accordion")
```

### Visibility Control

```elixir
# Show element
JS.show(to: "#modal", transition: "fade-in")

# Hide element
JS.hide(to: "#overlay", transition: "fade-out")

# Toggle visibility
JS.toggle(to: ".details")
```

### Animations and Transitions

```elixir
# Apply transition with timing
JS.transition(
  {"transition-all duration-300", "opacity-0", "opacity-100"},
  to: ".alert"
)
```

## Push Events with Enhanced Options

The `JS.push` command extends default event handling:

```elixir
# Basic push
JS.push("update_count")

# With target component
JS.push("increment", target: @myself)

# With loading state
JS.push("save", loading: "btn-saving", disabled: [".form"])

# With custom payload
JS.push("search", value: %{"query" => "term"})

# Combine multiple options
JS.push("submit",
  target: @myself,
  loading: "opacity-50",
  value: %{"id" => @id}
)
```

**Push Options:**

```elixir
target: @myself           # Route to specific component
loading: "css-class"      # Class applied during request
disabled: [".selector"]   # Elements disabled during request
value: %{"key" => "val"}  # Custom payload data
```

## Selector Scoping

Commands support flexible element targeting:

```elixir
# Standard CSS selectors
JS.add_class("active", to: ".menu-item")
JS.add_class("active", to: "#primary")

# Scoped selectors
JS.add_class("active", to: {:inner, ".child"})     # Within element
JS.add_class("active", to: {:closest, ".parent"})  # Ancestor traversal

# Self reference (current element)
JS.add_class("selected")  # Targets element with event
```

## Event Dispatching

Trigger custom JavaScript event listeners:

```elixir
# Dispatch event
JS.dispatch("custom:event", to: "#modal", detail: %{"id" => 123})

# In template, trigger with phx-click
<button phx-click={JS.dispatch("modal:open", detail: %{"id" => @id})}>
  Open Modal
</button>
```

**Custom Event Listener (JavaScript):**

```javascript
window.addEventListener("custom:event", (e) => {
  console.log(e.detail); // Access dispatched data
  // Handle event
});
```

## Command Composition

Chain multiple operations using the pipe operator:

```elixir
# Execute sequence of commands
<button phx-click={
  JS.add_class("loading", to: "button")
  |> JS.disable_form("#form")
  |> JS.push("submit", target: @myself)
}>
  Submit
</button>

# More complex composition
<div phx-click={
  JS.show(to: "#modal", transition: "fade-in")
  |> JS.dispatch("modal:opened")
  |> JS.focus(to: "#input")
}>
  Click to open
</div>
```

## Form Handling

### Form Disabling

Disable form submission during async operations:

```elixir
<.form for={@form} phx-submit={JS.disable_form("submit_btn") |> JS.push("save")}>
  <input type="text" />
  <button id="submit_btn" type="submit">Save</button>
</.form>
```

### Focus Management

```elixir
# Focus on error input
JS.focus(to: "#email_input")

# Focus within scoped element
JS.focus(to: {:inner, "input"})
```

## Integration with Hooks

Custom JavaScript hooks can work with LiveView commands:

```elixir
def render(assigns) do
  ~H"""
  <div id="my_element" phx-hook="MyHook">
    <button phx-click={JS.push("custom")}>
      Click
    </button>
  </div>
  """
end
```

**JavaScript Hook:**

```javascript
Hooks.MyHook = {
  mounted() {
    this.el.addEventListener("custom", (e) => {
      // Handle LiveView push
      this.pushEvent("custom", {});
    });
  },
};
```

## Phx- Bindings for Events

Common LiveView event bindings:

```html
<!-- Click events -->
<button phx-click="increment">+</button>

<!-- Input changes (with debouncing) -->
<input type="text" phx-change="search" phx-debounce="300" />

<!-- Form submission -->
<form phx-submit="save"></form>

<!-- Input events -->
<input phx-blur="field_blur" phx-focus="field_focus" />

<!-- Disable element during async -->
<button phx-disable-with="Saving...">Save</button>

<!-- Throttle events -->
<input phx-change="scroll" phx-throttle="1000" />
```

## Real-Time Class Application

Apply loading states during operations:

```html
<!-- Add class during phx-change -->
<form phx-change="validate">
  <!-- Form receives phx-change-loading class -->
  <input type="text" />
</form>
```

**CSS for loading state:**

```css
.phx-change-loading {
  opacity: 0.6;
  pointer-events: none;
}

.phx-submit-loading {
  opacity: 0.6;
  pointer-events: none;
}
```

## Advanced Patterns

### Modal Control

```elixir
# Open modal with animation
<button phx-click={
  JS.show(to: "#modal-backdrop", transition: {"ease-out duration-300", "opacity-0", "opacity-100"})
  |> JS.show(to: "#modal", transition: {"ease-out duration-300", "scale-95", "scale-100"})
  |> JS.focus(to: "#modal input")
}>
  Open Modal
</button>

# Close modal
def handle_event("close_modal", _params, socket) do
  {:noreply, socket}
end
```

### Conditional Command Execution

```elixir
<button phx-click={
  if @saving do
    JS.noop()  # Do nothing if already saving
  else
    JS.push("save") |> JS.disable()
  end
}>
  Save
</button>
```

### Multi-step Operations

```elixir
# Disable form, show loader, push event
<form phx-submit={
  JS.add_class("opacity-50", to: ".form")
  |> JS.show(to: "#loader")
  |> JS.push("validate")
}>
  <!-- form inputs -->
</form>
```

## Best Practices

**Client-Side Validation:** Use JS commands for immediate UI feedback without server round-trips:

```elixir
<input phx-change={
  JS.dispatch("input:validate", detail: %{"value" => "value"})
} />
```

**Loading States:** Always provide visual feedback during async operations:

```elixir
phx-submit={JS.add_class("loading") |> JS.push("save")}
```

**Accessibility:** Maintain focus management and ARIA attributes:

```elixir
JS.focus(to: "#error-message") |> JS.set_attribute({"role", "alert"})
```

**Avoid Over-Engineering:** Keep DOM manipulation simple; use LiveView state for complex logic:

```elixir
# Good: simple visual effect
JS.add_class("highlight")

# Less ideal: complex logic in JS
JS.dispatch("complex-calc", detail: %{...})
```

---

[← Back to main](phoenix_live_view-1.1.32.md)  
**Version:** 1.1.32
